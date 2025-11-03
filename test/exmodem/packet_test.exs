defmodule Exmodem.PacketTest do
  use ExUnit.Case
  alias Exmodem.Packet
  doctest Exmodem.Packet

  test "build packet(s)" do
    packet = Packet.build(1, "Hello, world!")
    padding = :binary.copy(<<0x1A>>, 115)
    assert <<1, 1, 254, "Hello, world!"::binary, ^padding::binary, 55>> = packet

    packet = Packet.build(1, "Hello, world!", checksum_mode: :crc)
    padding = :binary.copy(<<0x1A>>, 115)
    assert <<1, 1, 254, "Hello, world!"::binary, ^padding::binary, 29859::16>> = packet

    packet = Packet.build(2, "Hello, world!", checksum_mode: :crc, packet_size: 1024)
    padding = :binary.copy(<<0x1A>>, 1011)
    assert <<2, 2, 253, "Hello, world!"::binary, ^padding::binary, _::16>> = packet
  end
end
