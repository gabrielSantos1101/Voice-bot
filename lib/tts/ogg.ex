defmodule ArcaneVoice.TTS.Ogg do
  @moduledoc false

  require Logger

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
    case group_segments_into_packets(lengths, data) do
      [first | _] when is_binary(first) ->
        if String.starts_with?(first, "OpusHead"), do: %{acc | is_opuss: true}, else: acc
      _ ->
        acc
    end
  end

  defp process_page({_header_type, _granule, lengths, data}, %__MODULE__{} = acc) do
    packets = group_segments_into_packets(lengths, data)
    audio_packets = Enum.reject(packets, &String.starts_with?(&1, "OpusTags"))
    Logger.debug("Ogg: page with #{length(lengths)} segments → #{length(audio_packets)} audio packets")
    %{acc | packets: audio_packets ++ acc.packets}
  end

  defp group_segments_into_packets(lengths, data) do
    {packets, _rest} = do_group(lengths, data, <<>>, [])
    Enum.reverse(packets)
  end

  defp do_group([], rest, _acc, packets), do: {packets, rest}
  defp do_group([len | rest], data, acc, packets) do
    <<seg::binary-size(len), remaining::binary>> = data
    if len < 255 do
      packet = <<acc::binary, seg::binary>>
      do_group(rest, remaining, <<>>, [packet | packets])
    else
      do_group(rest, remaining, <<acc::binary, seg::binary>>, packets)
    end
  end
end