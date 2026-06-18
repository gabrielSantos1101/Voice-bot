defmodule ArcaneVoice.TTS.Opus do
  @moduledoc false

  require Logger

  alias ArcaneVoice.TTS.Ogg

  @debug_dir System.tmp_dir!() <> "/arcane_voice_debug"

  @sample_rate 48_000
  @frame_duration_ms 20

  def encode(pcm_data, bitrate \\ 64_000) do
    File.mkdir_p!(@debug_dir)
    tmp_in = tmp_path("pcm")
    tmp_out = Path.join(@debug_dir, "last.opus")
    File.write!(tmp_in, pcm_data)
    disk_size = byte_size(File.read!(tmp_in))
    Logger.info("Opus: PCM written #{byte_size(pcm_data)}b to disk, readback #{disk_size}b")

    pcm_size = byte_size(pcm_data)
    chk = fn offset ->
      if pcm_size >= offset + 1000 do
        pcm_data |> binary_part(offset, 1000) |> :binary.bin_to_list() |> Enum.count(&(&1 != 0))
      else 0 end
    end
    nz_start = chk.(0)
    nz_mid = if pcm_size >= 48000, do: chk.(div(pcm_size, 2) - 500), else: 0
    nz_end = if pcm_size >= 2000, do: chk.(pcm_size - 1000), else: 0

    first_nz = pcm_data |> :binary.bin_to_list() |> Enum.find_index(&(&1 != 0))
    mid_start = div(pcm_size, 2) - 960  # one 20ms frame
    mid_frame = if mid_start >= 0 && mid_start + 1920 <= pcm_size, do: binary_part(pcm_data, mid_start, 1920) |> :binary.bin_to_list(), else: []
    mid_min = if mid_frame != [], do: Enum.min(mid_frame), else: 0
    mid_max = if mid_frame != [], do: Enum.max(mid_frame), else: 0

    Logger.info("Opus: PCM input #{pcm_size} bytes, non-zero: start=#{nz_start} mid=#{nz_mid} end=#{nz_end}, first_nz=#{inspect(first_nz)}, mid_frame min=#{mid_min} max=#{mid_max}")

    args = [
      "-f", "s16le",
      "-ar", "#{@sample_rate}",
      "-ac", "1",
      "-i", tmp_in,
      "-c:a", "libopus",
      "-b:a", "#{bitrate}",
      "-ar", "#{@sample_rate}",
      "-ac", "1",
      "-frame_duration", "#{@frame_duration_ms}",
      "-nostdin",
      "-y",
      "-f", "ogg",
      "-loglevel", "error",
      tmp_out
    ]

    result =
      case System.cmd("ffmpeg", args) do
        {_output, 0} ->
          ogg_data = File.read!(tmp_out)
          Logger.info("Opus: OGG saved to #{tmp_out} (#{byte_size(ogg_data)} bytes)")
          ArcaneVoice.Debug.set(:ogg, tmp_out)

          case Ogg.parse(ogg_data) do
            {:ok, frames} ->
              first_5 = Enum.take(frames, 5)
              frame_sizes = first_5 |> Enum.map(&byte_size/1) |> inspect()
              frame_bytes = first_5 |> Enum.map(fn f -> if byte_size(f) >= 4, do: Base.encode16(binary_part(f, 0, 4)), else: Base.encode16(f) end) |> inspect()
              Logger.info("Opus: parsed #{length(frames)} frames, first 5 sizes: #{frame_sizes}, hex: #{frame_bytes}")
              timestamps = build_timestamps(length(frames))
              {:ok, Enum.zip(timestamps, frames)}

            error ->
              Logger.error("Opus: Ogg parse failed: #{inspect(error)}")
              error
          end

        {output, code} ->
          {:error, "ffmpeg opus encoding failed (exit #{code}): #{output}"}
      end

    File.rm(tmp_in)
    result
  end

  defp build_timestamps(count) do
    Stream.iterate(0, &(&1 + @frame_duration_ms))
    |> Enum.take(count)
  end

  defp tmp_path(ext), do: Path.join(System.tmp_dir!(), "tts_opus_#{System.unique_integer([:positive])}.#{ext}")
end
