defmodule LRZWriter do
  @moduledoc false
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, Keyword.merge(opts, test_pid: self()))
  end

  def init(opts) do
    data = Keyword.fetch!(opts, :data)
    outfile = Keyword.fetch!(opts, :outfile)
    test_pid = Keyword.fetch!(opts, :test_pid)
    checksum_mode = Keyword.get(opts, :checksum_mode, :crc)
    extra_lrz_args = Keyword.get(opts, :extra_lrz_args, [])
    lrz = System.find_executable("lrz") || System.find_executable("rz")

    args =
      if checksum_mode == :crc do
        ["-q", "--with-crc", "--xmodem"] ++ extra_lrz_args ++ [outfile]
      else
        ["-q", "--xmodem"] ++ extra_lrz_args ++ [outfile]
      end

    port =
      Port.open({:spawn_executable, lrz}, [
        :binary,
        :stream,
        :use_stdio,
        :exit_status,
        {:args, args}
      ])

    {:ok, driver} = Exmodem.start_link(data, opts)

    {:ok, %{lrz: port, driver: driver, test_pid: test_pid}}
  end

  def handle_info({lrz, {:data, data}}, %{lrz: lrz} = state) do
    case Exmodem.receive_data(state.driver, data) do
      {:send, to_send} ->
        Port.command(lrz, to_send)

      :ignore ->
        :ok

      :done ->
        Logger.debug("Transfer complete")
        Port.close(lrz)
    end

    {:noreply, state}
  end

  def handle_info({lrz, {:exit_status, _}}, %{lrz: lrz, test_pid: test_pid} = state) do
    send(test_pid, :done)
    {:stop, :normal, state}
  end
end
