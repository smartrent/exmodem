defmodule ExmodemTest do
  use ExUnit.Case, async: true

  setup do
    tmpdir = System.tmp_dir!()
    outfile = Path.join(tmpdir, "test-#{System.unique_integer([:positive, :monotonic])}")

    on_exit(fn -> File.rm(outfile) end)

    %{outfile: outfile}
  end

  test "cancellation" do
    {:ok, driver} = Exmodem.start_link("0123456789ABCDEF\n")

    assert {:send, <<1, 1, _rest::binary>>} = Exmodem.receive_data(driver, <<?C>>)
    assert :ignore = Exmodem.receive_data(driver, <<0x18>>)
    assert {:error, :canceled_by_receiver} = Exmodem.receive_data(driver, <<0x18>>)
  end

  test "naks and retries" do
    {:ok, driver} = Exmodem.start_link("0123456789ABCDEF\n")

    assert {:send, <<1, 1, _rest::binary>> = packet} = Exmodem.receive_data(driver, <<?C>>)
    assert {:send, ^packet} = Exmodem.receive_data(driver, <<0x15>>)
    assert {:send, ^packet} = Exmodem.receive_data(driver, <<0x15>>)
    assert {:error, :max_retries_exceeded} = Exmodem.receive_data(driver, <<0x15>>)
  end

  test "xmodem-1k" do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 10000)

    {:ok, pid} =
      Exmodem.start_link(:binary.copy(<<"0123456789ABCDEF\n">>, 10000), packet_size: 1024)

    p1 = binary_slice(data, 0, 1024)

    assert {:send, <<2, 1, 254, ^p1::1024-bytes, _::16>> = packet} =
             Exmodem.receive_data(pid, <<?C>>)

    p2 = binary_slice(data, 1024, 1024)

    assert {:send, <<2, 2, 253, ^p2::binary, _::16>> = packet} =
             Exmodem.receive_data(pid, <<0x06>>)
  end

  test "timeouts" do
    Process.flag(:trap_exit, true)

    {:ok, driver} = Exmodem.start_link("0123456789ABCDEF\n", recv_timeout: 100)

    assert {:send, <<1, 1, _rest::binary>>} = Exmodem.receive_data(driver, <<?C>>)

    assert_receive {:EXIT, ^driver, :timeout}, 500
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

  test "lrz ~160kb w/ alt padding", %{outfile: outfile} do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 10000)

    {:ok, _pid} = LRZWriter.start_link(data: data, outfile: outfile, padding: <<0x00>>)

    assert_receive :done, 10_000

    written_data = outfile |> File.read!() |> String.trim_trailing(<<0x00>>)

    assert data == written_data
  end

  test "lrz ~160kb in checksum mode", %{outfile: outfile} do
    data = :binary.copy(<<"0123456789ABCDEF\n">>, 10000)

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
