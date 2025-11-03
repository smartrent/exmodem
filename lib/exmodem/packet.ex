defmodule Exmodem.Packet do
  @moduledoc """
  Utilities for building XMODEM packets.
  """

  @type packet_opt ::
          {:padding, <<_::8>>}
          | {:packet_size, pos_integer()}
          | {:checksum_mode, :crc | :checksum}

  @type checksum_mode :: :crc | :checksum

  # Start Of Header (128 byte packets)
  @soh 0x01
  # Start Of eXtended header (1024 byte packets)
  @stx 0x02

  @spec build(1..255, binary(), [packet_opt()]) :: binary()
  def build(packet_number, data, opts \\ []) do
    checksum_mode = Keyword.get(opts, :checksum_mode, :checksum)
    packet_size = Keyword.get(opts, :packet_size, 128)
    padding = Keyword.get(opts, :padding, <<0x1A>>)

    data = pad(data, packet_size, padding)
    checksum = checksum(data, checksum_mode)

    checksum_size =
      case checksum_mode do
        :crc -> 16
        :checksum -> 8
      end

    soh =
      case packet_size do
        128 -> @soh
        1024 -> @stx
      end

    <<soh, packet_number, 255 - packet_number, data::binary, checksum::size(checksum_size)>>
  end

  @doc """
  Calculates the checksum of the given data based on the specified checksum type.
  """
  @spec checksum(binary(), checksum_mode()) :: 0..0xFFFF
  def checksum(data, checksum_mode) do
    case checksum_mode do
      :crc -> calc_crc(data)
      :checksum -> calc_checksum(data)
    end
  end

  @doc """
  Calculates a simple checksum by summing the byte values of the data
  and taking the modulo 256 of the result.
  """
  @spec calc_checksum(binary()) :: char()
  def calc_checksum(data) do
    data |> :erlang.binary_to_list() |> Enum.sum() |> rem(256)
  end

  @crc16_ccitt_zero :cerlc.init(:crc16_ccitt_zero)

  @doc """
  Calculates the CRC-16-CCITT (zero) checksum of the given binary data.
  """
  @spec calc_crc(binary()) :: 0..0xFFFF
  def calc_crc(data) do
    :cerlc.calc_crc(data, @crc16_ccitt_zero)
  end

  @doc """
  Pads the given binary to the specified length using the provided padding byte.
  """
  @spec pad(binary(), pos_integer(), <<_::8>>) :: binary()
  def pad(binary, len, padding \\ <<0x00>>)

  def pad(binary, len, padding) when byte_size(binary) < len do
    binary <> :binary.copy(padding, len - byte_size(binary))
  end

  def pad(binary, _len, _padding), do: binary
end
