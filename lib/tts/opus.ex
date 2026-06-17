defmodule ArcaneVoice.TTS.Opus do
  @moduledoc false

  alias ArcaneVoice.TTS.Ogg

  @sample_rate 48_000
  @frame_duration_ms 20

  def encode(pcm_data, bitrate \\ 64_000) do
    tmp_in = tmp_path("pcm")
    tmp_out = tmp_path("opus")
    File.write!(tmp_in, pcm_data)

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
      "-f", "opus",
      "-loglevel", "error",
      tmp_out
    ]

    result =
      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_, 0} ->
          ogg_data = File.read!(tmp_out)

          case Ogg.parse(ogg_data) do
            {:ok, frames} ->
              timestamps = build_timestamps(length(frames))
              {:ok, Enum.zip(timestamps, frames)}

            error ->
              error
          end

        {output, code} ->
          {:error, "ffmpeg opus encoding failed (exit #{code}): #{output}"}
      end

    File.rm(tmp_in)
    File.rm(tmp_out)
    result
  end

  defp build_timestamps(count) do
    Stream.iterate(0, &(&1 + @frame_duration_ms))
    |> Enum.take(count)
  end

  defp tmp_path(ext), do: Path.join(System.tmp_dir!(), "tts_opus_#{System.unique_integer([:positive])}.#{ext}")
end
