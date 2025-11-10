defmodule ExmodemTest do
  use ExUnit.Case, async: true

  setup do
    tmpdir = System.tmp_dir!()
    outfile = Path.join(tmpdir, "test-#{System.unique_integer([:positive, :monotonic])}")

    on_exit(fn -> File.rm(outfile) end)

    %{outfile: outfile}
  end

  test "happy path" do
    {:ok, driver} = Exmodem.start_link(:binary.copy("0123456789ABCDEF\n", 20))

    assert {0, 3} = Exmodem.progress(driver)
    assert {:send, <<1, 1, _rest::binary>>} = Exmodem.receive_data(driver, <<?C>>)
    assert {1, 3} = Exmodem.progress(driver)
    assert {:send, <<1, 2, _rest::binary>>} = Exmodem.receive_data(driver, <<0x06>>)
    assert {2, 3} = Exmodem.progress(driver)
    assert {:send, <<1, 3, _rest::binary>>} = Exmodem.receive_data(driver, <<0x06>>)
    assert {3, 3} = Exmodem.progress(driver)

    assert {:send, <<0x04>>} = Exmodem.receive_data(driver, <<0x06>>)
    assert {:send, <<0x17>>} = Exmodem.receive_data(driver, <<0x06>>)
    assert :done = Exmodem.receive_data(driver, <<0x06>>)
  end

  test "cancellation" do
    {:ok, driver} = Exmodem.start_link("0123456789ABCDEF\n")

    assert {:send, <<1, 1, _rest::binary>>} = Exmodem.receive_data(driver, <<?C>>)
    assert :ignore = Exmodem.receive_data(driver, <<0x18>>)
    assert {:error, :canceled_by_receiver} = Exmodem.receive_data(driver, <<0x18>>)

    {:ok, driver} = Exmodem.start_link("0123456789ABCDEF\n")

    assert {:send, <<1, 1, _rest::binary>>} = Exmodem.receive_data(driver, <<?C>>)
    assert {:send, <<0x18, 0x18>>} = Exmodem.cancel(driver)
    refute Process.alive?(driver)

    assert {:error, :no_process} = Exmodem.receive_data(driver, <<0x06>>)
    assert {:error, :no_process} = Exmodem.progress(driver)
    assert :ok = Exmodem.cancel(driver)
    assert :ok = Exmodem.stop(driver)
  end

  test "naks and retries" do
    {:ok, driver} = Exmodem.start_link("0123456789ABCDEF\n")

    assert {:send, <<1, 1, _rest::binary>> = packet} = Exmodem.receive_data(driver, <<?C>>)
    assert {:send, ^packet} = Exmodem.receive_data(driver, <<0x15>>)
    assert {:send, ^packet} = Exmodem.receive_data(driver, <<0x15>>)
    assert {:error, :max_retries_exceeded} = Exmodem.receive_data(driver, <<0x15>>)
  end

  test "xmodem-1k" do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 1000)

    {:ok, pid} = Exmodem.start_link(data, packet_size: 1024)

    p1 = binary_slice(data, 0, 1024)
    assert {:send, <<2, 1, 254, ^p1::1024-bytes, _::16>>} = Exmodem.receive_data(pid, <<?C>>)

    p2 = binary_slice(data, 1024, 1024)
    assert {:send, <<2, 2, 253, ^p2::binary, _::16>>} = Exmodem.receive_data(pid, <<0x06>>)
  end

  test "timeouts" do
    Process.flag(:trap_exit, true)

    {:ok, driver} = Exmodem.start_link("0123456789ABCDEF\n", recv_timeout: 100)

    assert {:send, <<1, 1, _rest::binary>>} = Exmodem.receive_data(driver, <<?C>>)

    assert_receive {:EXIT, ^driver, :timeout}, 500
  end

  test "error handling", %{outfile: outfile} do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 1000)

    {:ok, _pid} =
      LRZWriter.start_link(
        data: data,
        outfile: outfile,
        # lrz will generate a crc error every 2359 bytes. this must be at least
        # 10% of the data size because lrz will abort a transfer if more than 10
        # errors occur in total
        extra_lrz_args: ~w(--errors 2359)
      )

    assert_receive :done, 10_000

    written_data = outfile |> File.read!() |> String.trim_trailing(<<0x1A>>)

    assert data == written_data
  end

  test "lrz ~160kb", %{outfile: outfile} do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 10000)

    {:ok, _pid} =
      LRZWriter.start_link(
        data: data,
        outfile: outfile
      )

    assert_receive :done, 10_000

    written_data = outfile |> File.read!() |> String.trim_trailing(<<0x1A>>)

    assert data == written_data
  end

  test "lrz ~16kb w/ alt padding", %{outfile: outfile} do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 1000)

    {:ok, _pid} = LRZWriter.start_link(data: data, outfile: outfile, padding: <<0x00>>)

    assert_receive :done, 10_000

    written_data = outfile |> File.read!() |> String.trim_trailing(<<0x00>>)

    assert data == written_data
  end

  test "lrz ~16kb in checksum mode", %{outfile: outfile} do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 1000)

    {:ok, _pid} =
      LRZWriter.start_link(
        data: data,
        outfile: outfile,
        padding: <<0x00>>,
        checksum_mode: :checksum
      )

    assert_receive :done, 10_000

    written_data = outfile |> File.read!() |> String.trim_trailing(<<0x00>>)

    assert data == written_data
  end
end
