defmodule ArcaneVoice.TTS.Ogg do
  @moduledoc false

  require Logger

  defstruct packets: [], is_opuss: false, pending: <<>>

  def parse(data) do
    result = parse_pages(data, %__MODULE__{})
    case result do
      {:ok, res} ->
        {:ok, Enum.reverse(res.packets)}
      error -> error
    end
  end

  defp parse_pages(<<>>, acc) do
    {:ok, finalize(acc)}
  end

  defp parse_pages(<<"OggS", _::binary>> = data, acc) do
    with {:ok, page, rest} <- take_page(data) do
      acc = process_page(page, acc)
      parse_pages(rest, acc)
    end
  end

  defp parse_pages(_data, acc) do
    {:ok, Enum.reverse(acc.packets)}
  end

  defp take_page(<<"OggS", version::8, _header_type::8,
                   granule::64-little, _serial::32-little,
                   _page_seq::32-little, _crc::32-little,
                   num_segments::8, after_header::binary>>) when version == 0 do
    <<seg_table::binary-size(num_segments), page_data::binary>> = after_header
    seg_lengths = for <<len::8 <- seg_table>>, do: len
    total = Enum.sum(seg_lengths)
    <<seg_data::binary-size(total), remaining::binary>> = page_data
    {:ok, {granule, seg_lengths, seg_data}, remaining}
  end

  defp take_page(_), do: :error

  defp process_page({_granule, lengths, data}, %__MODULE__{is_opuss: false} = acc) do
    {packets, _pend} = extract_packets(lengths, data, <<>>)
    case packets do
      [first | _] when is_binary(first) and byte_size(first) >= 8 ->
        head = binary_part(first, 0, 8)
        if head == "OpusHead" do
          Logger.info("Ogg: found OpusHead (#{byte_size(first)}b)")
          %{acc | is_opuss: true}
        else
          acc
        end
      _ ->
        acc
    end
  end

  defp process_page({granule, lengths, data}, %__MODULE__{} = acc) do
    {packets, pending} = extract_packets(lengths, data, acc.pending)
    audio = Enum.reject(packets, fn p ->
      byte_size(p) >= 8 and binary_part(p, 0, 8) == "OpusTags"
    end)
    total_seg = Enum.sum(lengths)
    Logger.info("Ogg: page granule=#{granule} segs=#{inspect(lengths)} total=#{total_seg}b " <>
      "→ #{length(audio)} audio pkts (#{Enum.sum(Enum.map(audio, &byte_size/1))}b) pending=#{byte_size(pending)}b")
    %{acc | packets: Enum.reverse(audio) ++ acc.packets, pending: pending}
  end

  # Build Opus packets from segment lengths.
  # Segments with len < 255 terminate the current packet.
  # Segments with len == 255 continue the packet.
  defp extract_packets([], _data, pending), do: {[], pending}

  defp extract_packets(lengths, data, pending_acc) do
    {packets_rev, final_pending} = group(lengths, data, pending_acc, [])
    {Enum.reverse(packets_rev), final_pending}
  end

  defp group([], _data, acc, packets), do: {packets, acc}

  defp group([len | rest], data, acc, packets) do
    <<seg::binary-size(len), remaining::binary>> = data
    new_acc = <<acc::binary, seg::binary>>
    if len < 255 do
      group(rest, remaining, <<>>, [new_acc | packets])
    else
      group(rest, remaining, new_acc, packets)
    end
  end

  defp finalize(%__MODULE__{packets: packets, pending: pending} = acc) do
    if pending != <<>> do
      Logger.info("Ogg: finalizing with #{byte_size(pending)}b pending")
      %{acc | packets: [pending | packets]}
    else
      acc
    end
  end
end