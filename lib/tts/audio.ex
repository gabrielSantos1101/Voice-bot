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
    ts = System.system_time(:millisecond)
    mp3_path = Path.join(@debug_dir, "tts_#{ts}.#{extension}")
    File.write!(mp3_path, audio_data)
    Logger.info("Audio: saved MP3 to #{mp3_path} (#{byte_size(audio_data)} bytes)")

    pcm_path = Path.join(@debug_dir, "tts_#{ts}.pcm")

    args = [
      "-i", mp3_path,
      "-f", "s16le",
      "-acodec", "pcm_s16le",
      "-ar", "48000",
      "-ac", "1",
      "-af", "volume=2.0",
      "-loglevel", "error",
      pcm_path
    ]

    result =
      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_, 0} ->
          pcm = File.read!(pcm_path)
          pcm_size = byte_size(pcm)
          first_bytes = if pcm_size >= 4, do: Base.encode16(binary_part(pcm, 0, 4)), else: "too small"
          Logger.info("Audio: PCM saved to #{pcm_path} (#{pcm_size} bytes, first_bytes=#{first_bytes})")
          ArcaneVoice.Debug.set(:pcm, pcm_path)
          ArcaneVoice.Debug.set(:mp3, mp3_path)
          {:ok, pcm}
        {output, exit_code} ->
          {:error, "ffmpeg failed (exit #{exit_code}): #{output}"}
      end

    result
  end
end
