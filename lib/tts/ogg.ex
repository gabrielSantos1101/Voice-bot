defmodule ArcaneVoice.TTS.Ogg do
  @moduledoc false

  defstruct packets: [], is_opuss: false

  def parse(data) do
    case parse_pages(data, %__MODULE__{}) do
      {:ok, result} -> {:ok, Enum.reverse(result.packets)}
      error -> error
    end
  end

  defp parse_pages(<<>>, acc), do: {:ok, acc}
  defp parse_pages(<<"OggS", _rest::binary>> = data, acc) do
    with {:ok, page, rest} <- take_page(data) do
      acc = process_page(page, acc)
      parse_pages(rest, acc)
    end
  end
  defp parse_pages(_data, acc), do: {:ok, Enum.reverse(acc.packets)}

  defp take_page(<<"OggS", version::8, header_type::8,
                   granule::64-little, _serial::32-little,
                   _page_seq::32-little, _crc::32-little,
                   num_segments::8, rest::binary>>) when version == 0 do
    <<segment_table::binary-size(num_segments), page_data::binary>> = rest
    segment_lengths = for <<len::8 <- segment_table>>, do: len
    total_len = Enum.sum(segment_lengths)
    <<packets_data::binary-size(total_len), remaining::binary>> = page_data
    {:ok, {header_type, granule, segment_lengths, packets_data}, remaining}
  end
  defp take_page(<<>>), do: :error

  defp process_page({_header_type, _granule, lengths, data}, %__MODULE__{is_opuss: false} = acc) do
    packet = extract_first_packet(data, lengths)
    if packet && String.starts_with?(packet, "OpusHead") do
      %{acc | is_opuss: true}
    else
      acc
    end
  end

  defp process_page({_header_type, _granule, lengths, data}, %__MODULE__{} = acc) do
    packets = extract_all_packets(data, lengths, [])
    packets = Enum.reject(packets, &String.starts_with?(&1, "OpusTags"))
    %{acc | packets: packets ++ acc.packets}
  end

  defp extract_first_packet(data, [first_len | _rest]), do: binary_part(data, 0, first_len)
  defp extract_first_packet(_, []), do: nil

  defp extract_all_packets(_data, [], packets), do: Enum.reverse(packets)
  defp extract_all_packets(data, [len | rest], packets) do
    <<packet::binary-size(len), remaining::binary>> = data
    extract_all_packets(remaining, rest, [packet | packets])
  end
end