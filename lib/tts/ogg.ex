defmodule ArcaneVoice.TTS.Ogg do
  @moduledoc false

  require Logger

  defstruct packets: [], is_opuss: false, pending: <<>>

  def parse(data) do
    case parse_pages(data, %__MODULE__{}) do
      {:ok, result} ->
        packets = if result.pending == <<>>, do: result.packets, else: [result.pending | result.packets]
        {:ok, Enum.reverse(packets)}
      error -> error
    end
  end

  defp parse_pages(<<>>, acc) do
    final_packets = if acc.pending != <<>>, do: [acc.pending | acc.packets], else: acc.packets
    {:ok, %{acc | packets: final_packets, pending: <<>>}}
  end
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
    {packets, _pending} = group_into_packets(lengths, data, acc.pending)
    case packets do
      [first | _] when is_binary(first) ->
        if String.starts_with?(first, "OpusHead"), do: %{acc | is_opuss: true, pending: <<>>}, else: acc
      _ ->
        acc
    end
  end

  defp process_page({_header_type, _granule, lengths, data}, %__MODULE__{} = acc) do
    {packets, pending} = group_into_packets(lengths, data, acc.pending)
    audio_packets = Enum.reject(packets, &String.starts_with?(&1, "OpusTags"))
    Logger.debug("Ogg: page #{length(lengths)} segs → #{length(audio_packets)} pkts, pending=#{byte_size(pending)}b")
    %{acc | packets: audio_packets ++ acc.packets, pending: pending}
  end

  defp group_into_packets(lengths, data, pending_acc) do
    {packets, pending} = do_group(lengths, data, pending_acc, [])
    {Enum.reverse(packets), pending}
  end

  defp do_group([], _rest, acc, packets), do: {packets, acc}
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