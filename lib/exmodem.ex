defmodule Exmodem do
  @moduledoc """
  State machine implementing the XMODEM file transfer protocol.

  ## Example: Circuits.UART

      defmodule XmodemUART do
        use GenServer

        require Logger

        def start_link(opts \\ []) do
          GenServer.start_link(__MODULE__, opts)
        end

        @impl GenServer
        def init(opts) do
          data = Keyword.fetch!(opts, :data)
          {:ok, driver} = Exmodem.start_link(data)

          {:ok, uart} = Circuits.UART.start_link()
          :ok = Circuits.UART.open(uart, Keyword.fetch!(opts, :device), speed: 115200)

          {:ok, %{uart: uart, driver: driver}}
        end

        def handle_info({:circuits_uart, _port, data}, state) do
          case Exmodem.receive_data(driver, data) do
            {:send, to_send} ->
              Circuits.UART.write(uart, to_send)

            :ignore ->
              :ok

            :done ->
              IO.puts("Transfer complete")
          end

          {:noreply, state}
        end
      end

      XmodemUART.start_link(data: "Hello, World!", device: "/dev/ttyUSB0")
  """

  require Logger

  @behaviour :gen_statem

  @eot 0x04
  @ack 0x06
  @nak 0x15
  @etb 0x17
  @can 0x18
  @c ?C

  @typedoc """
  Options for the XMODEM transfer.

  ## Options

    * `:packet_size` - The size of each packet. Default is 128 bytes.
    * `:padding` - The byte used for padding the last packet if the transfer is
      not a multiple of `:packet_size`. Default is `0x1A` (ASCII SUB).
    * `:max_retries` - The maximum number of consecutive retries of a single packet
      before aborting. Defaults to 2.
  """
  @type start_opt() ::
          {:packet_size, pos_integer()}
          | {:padding, <<_::8>>}
          | {:max_retries, non_neg_integer()}
          | {:recv_timeout, timeout()}

  @typedoc """
  The result of a command sent to the XMODEM driver indicates to the caller what
  action to take next.

  ## Results

    * `:ignore` - No action is needed. The caller should wait for further input
      from the server/receiver.
    * `:done` - The transfer is complete.
    * `{:send, binary()}` - The caller should send the given binary data to the
      receiver without modification.
    * `{:error, reason}` - An error occurred. The reason indicates the type of
      error.
  """
  @type command_result() ::
          :ignore
          | :done
          | {:send, binary()}
          | {:error,
             :canceled_by_receiver | :max_retries_exceeded | :unexpected_data | :no_process}

  @doc """
  Starts the XMODEM driver state machine.
  """
  @spec start_link(binary(), [start_opt()]) :: :gen_statem.start_ret()
  def start_link(input, opts \\ []) do
    :gen_statem.start_link(__MODULE__, [input, opts], [])
  end

  @doc """
  Handles incoming data from the receiver and returns the appropriate command
  result.
  """
  @spec receive_data(:gen_statem.server_ref(), binary()) :: command_result()
  def receive_data(server, data) do
    :gen_statem.call(server, {:receive, data})
  catch
    :exit, {:noproc, _} -> {:error, :no_process}
  end

  @doc """
  Cancels the current transfer by sending two CAN characters to the receiver.
  """
  @spec cancel(:gen_statem.server_ref()) :: command_result()
  def cancel(server) do
    :gen_statem.call(server, :sender_cancel)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Gets the progress of the current transfer as a tuple of
  `{sent_packets, total_packets}`.
  """
  def progress(server) do
    :gen_statem.call(server, :progress)
  catch
    :exit, {:noproc, _} -> {:error, :no_process}
  end

  @doc """
  Stops the XMODEM driver state machine.
  """
  @spec stop(:gen_statem.server_ref()) :: :ok
  def stop(server) do
    :gen_statem.stop(server, :normal, :timer.seconds(5))
  catch
    # gen_statem is weird
    :exit, :noproc -> :ok
    :exit, {:noproc, _} -> :ok
  end

  @impl :gen_statem
  def callback_mode(), do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init([input, opts]) do
    padding =
      case Keyword.get(opts, :padding, <<0x1A>>) do
        padding when is_binary(padding) and byte_size(padding) == 1 -> padding
        padding when padding in 0..255 -> <<padding>>
        other -> raise ArgumentError, "Invalid padding option: #{inspect(other)}"
      end

    packet_size = Keyword.get(opts, :packet_size, 128)

    {:ok, :init,
     %{
       buffer: input,
       sent_packets: 0,
       total_packets: ceil(byte_size(input) / packet_size),
       position: 0,
       packet_number: 1,
       checksum_mode: nil,
       recv_timeout: Keyword.get(opts, :recv_timeout, :timer.seconds(5)),
       packet_size: packet_size,
       max_retries: Keyword.get(opts, :max_retries, 2),
       padding: padding,
       retries: 0,
       cancels: 0
     }}
  end

  @impl :gen_statem

  ### STATE ENTER CALLBACKS

  # Whenever we enter the sending state (via :next_state or :repeat_state), reset
  # retries and cancels to 0
  def handle_event(:enter, _old_state, :sending, %{recv_timeout: recv_timeout} = data) do
    actions =
      if is_integer(recv_timeout) do
        [{:state_timeout, recv_timeout, :recv_timeout}]
      else
        []
      end

    {:next_state, :sending, %{data | retries: 0, cancels: 0}, actions}
  end

  def handle_event(:enter, _old_state, new_state, data) do
    {:next_state, new_state, data}
  end

  ### EVENT CALLBACKS

  # State timeout in the sending state
  def handle_event(:state_timeout, :recv_timeout, :sending, _data) do
    Logger.error("[Exmodem.Driver] Timeout waiting for receiver response")
    {:stop, :timeout}
  end

  # receive CAN when we've already received 1
  def handle_event({:call, from}, {:receive, <<@can>>}, _state, %{cancels: cancels})
      when cancels > 0 do
    {:stop_and_reply, :normal, [{:reply, from, {:error, :canceled_by_receiver}}]}
  end

  # receive CAN when we haven't received any yet
  def handle_event({:call, from}, {:receive, <<@can>>}, _state, %{cancels: cancels} = data) do
    {:keep_state, %{data | cancels: cancels + 1}, [{:reply, from, :ignore}]}
  end

  def handle_event({:call, from}, {:receive, <<char, _rest::binary>>}, :init, data)
      when char in [@nak, @c] do
    data = %{data | checksum_mode: if(char == @c, do: :crc, else: :checksum)}

    Logger.debug(
      "[Exmodem.Driver] Receiver requests checksum mode: #{inspect(data.checksum_mode)}"
    )

    packet = packet(data)

    {:next_state, :sending, %{data | cancels: 0, sent_packets: data.sent_packets + 1},
     [
       {:reply, from, {:send, packet}}
     ]}
  end

  # Ignore 'C' inputs when not in the init state.
  def handle_event({:call, from}, {:receive, <<@c, _rest::binary>>}, _state, data) do
    {:keep_state, %{data | cancels: 0}, [{:reply, from, :ignore}]}
  end

  # Ack when we already sent the last packet. Send EOT.
  def handle_event(
        {:call, from},
        {:receive, <<@ack>>},
        :sending,
        %{
          buffer: buffer,
          position: position,
          packet_size: packet_size
        } = data
      )
      when position + packet_size > byte_size(buffer) do
    {:next_state, :sent_eot, %{data | cancels: 0, retries: 0},
     [{:reply, from, {:send, <<@eot>>}}]}
  end

  # Ack when in sending state. Advance to the next packet and send it.
  def handle_event({:call, from}, {:receive, <<@ack>>}, :sending, data) do
    data = %{
      data
      | position: data.position + data.packet_size,
        packet_number: next_packet_number(data.packet_number),
        sent_packets: data.sent_packets + 1,
        cancels: 0,
        retries: 0
    }

    packet = packet(data)

    {:repeat_state, data, [{:reply, from, {:send, packet}}]}
  end

  # Receive nak when in sending state and exceeded max retries. Abort.
  def handle_event({:call, from}, {:receive, <<@nak>>}, :sending, %{
        max_retries: max_retries,
        retries: retries
      })
      when retries >= max_retries do
    {:stop_and_reply, :normal, [{:reply, from, {:error, :max_retries_exceeded}}]}
  end

  # Receive nak when in sending state. Retry sending the same packet.
  def handle_event({:call, from}, {:receive, <<@nak>>}, :sending, data) do
    data = %{data | retries: data.retries + 1}
    packet = packet(data)

    {:keep_state, %{data | cancels: 0},
     [
       {:reply, from, {:send, packet}}
     ]}
  end

  # ack when in sent_eot. send ETB.
  def handle_event({:call, from}, {:receive, <<@ack>>}, :sent_eot, data) do
    {:next_state, :sent_etb, data, [{:reply, from, {:send, <<@etb>>}}]}
  end

  # ack when in sent_etb. we're done.
  def handle_event({:call, from}, {:receive, <<@ack>>}, :sent_etb, _data) do
    {:stop_and_reply, :normal, [{:reply, from, :done}]}
  end

  def handle_event({:call, from}, {:receive, _other}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected_data}}]}
  end

  def handle_event({:call, from}, :sender_cancel, _state, _data) do
    {:stop_and_reply, :normal, [{:reply, from, {:send, <<@can, @can>>}}]}
  end

  def handle_event({:call, from}, :progress, _state, data) do
    {:keep_state_and_data,
     [
       {:reply, from, {data.sent_packets, data.total_packets}}
     ]}
  end

  defp packet(data) do
    buf = binary_slice(data.buffer, data.position, data.packet_size)

    Exmodem.Packet.build(data.packet_number, buf,
      checksum_mode: data.checksum_mode,
      packet_size: data.packet_size,
      padding: data.padding
    )
  end

  @spec next_packet_number(integer()) :: 0..255
  defp next_packet_number(current) do
    rem(current + 1, 256)
  end
end
