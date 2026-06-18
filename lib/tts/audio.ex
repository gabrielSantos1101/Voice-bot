defmodule ArcaneVoice.TTS.Audio do
  @moduledoc """
  Audio conversion utilities for TTS pipeline.

  All providers produce PCM s16le 48kHz mono for Discord voice.
  """

  @doc """
  Converts any audio binary (MP3, Opus, etc.) to PCM s16le 48kHz mono via FFmpeg.
  """
  def to_pcm(audio_data, extension \\ "mp3") do
    tmp_in = Path.join(System.tmp_dir!(), "tts_in_#{System.unique_integer([:positive])}.#{extension}")
    File.write!(tmp_in, audio_data)

    args = [
      "-i", tmp_in,
      "-f", "s16le",
      "-acodec", "pcm_s16le",
      "-ar", "48000",
      "-ac", "1",
      "-af", "volume=2.0",
      "-loglevel", "error",
      "-"
    ]

    result =
      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {pcm, 0} -> {:ok, pcm}
        {output, exit_code} -> {:error, "ffmpeg failed (exit #{exit_code}): #{output}"}
      end

    File.rm(tmp_in)
    result
  end
end
