defmodule ArcaneVoice.TTS.Engine.Edge do
  @moduledoc """
  TTS provider using Microsoft Edge's neural voices via edge-tts.

  Requires Python + `pip install edge-tts` on the system.

  Voices:
    - pt-BR-FranciscaNeural (default)
    - pt-BR-AntonioNeural
    - pt-BR-BrendaNeural
    - en-US-JennyNeural
    - en-US-GuyNeural
    - See https://speech.microsoft.com/portal/voicegallery
  """

  @behaviour ArcaneVoice.TTS.Engine

  alias ArcaneVoice.TTS.Audio

  @impl true
  def synthesize(text, voice, opts) do
    tmp_dir = opts[:tmp_dir] || System.tmp_dir!()
    out_path = Path.join(tmp_dir, "tts_#{System.unique_integer([:positive])}.mp3")

    args = [
      "--voice", voice,
      "--text", text,
      "--write-media", out_path
    ]

    case System.cmd("edge-tts", args, stderr_to_stdout: true) do
      {_, 0} ->
        mp3 = File.read!(out_path)
        Logger.info("EdgeTTS: produced MP3 #{byte_size(mp3)} bytes")
        File.rm(out_path)
        Audio.to_pcm(mp3, "mp3")

      {output, exit_code} ->
        {:error, "edge-tts failed (exit #{exit_code}): #{output}"}
    end
  end

  @impl true
  def describe_voice(voice), do: "Microsoft Edge Neural: #{voice}"

  def default_voice, do: "pt-BR-FranciscaNeural"
end
