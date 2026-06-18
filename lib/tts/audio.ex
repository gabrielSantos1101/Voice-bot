defmodule ArcaneVoice.TTS.Audio do
  @moduledoc """
  Audio conversion utilities for TTS pipeline.

  All providers produce PCM s16le 48kHz mono for Discord voice.
  """

  require Logger

  @debug_dir System.tmp_dir!() <> "/arcane_voice_debug"

  @doc """
  Converts any audio binary (MP3, Opus, etc.) to PCM s16le 48kHz mono via FFmpeg.
  """
  def to_pcm(audio_data, extension \\ "mp3") do
    File.mkdir_p!(@debug_dir)
    mp3_path = Path.join(@debug_dir, "last.mp3")
    File.write!(mp3_path, audio_data)
    Logger.info("Audio: saved MP3 to #{mp3_path} (#{byte_size(audio_data)} bytes)")

    pcm_path = Path.join(@debug_dir, "last.pcm")
    args = [
      "-i", mp3_path,
      "-f", "s16le",
      "-ar", "48000",
      "-ac", "1",
      "-y",
      "-loglevel", "debug",
      pcm_path
    ]

    result =
      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {output, 0} ->
          if File.exists?(pcm_path) do
            pcm = File.read!(pcm_path)
            pcm_size = byte_size(pcm)
            non_zero = if pcm_size >= 2000 do
              pcm |> binary_part(0, 2000) |> :binary.bin_to_list() |> Enum.count(&(&1 != 0))
            else
              0
            end
            Logger.info("Audio: PCM generated (#{pcm_size} bytes, first 2000 have #{non_zero} non-zero bytes)")
            Logger.info("Audio: ffmpeg log: #{String.slice(output, -2000, 2000)}")
            ArcaneVoice.Debug.set(:mp3, mp3_path)
            ArcaneVoice.Debug.set(:pcm, pcm_path)
            {:ok, pcm}
          else
            {:error, "ffmpeg didn't produce PCM file: #{output}"}
          end
        {output, exit_code} ->
          {:error, "ffmpeg failed (exit #{exit_code}): #{String.slice(output, -2000, 2000)}"}
      end

    result
  end
end
