defmodule ArcaneVoice.TTS.Engine.ElevenLabs do
  @moduledoc """
  TTS provider using ElevenLabs API.

  Requires ELEVENLABS_API_KEY env var.

  Voices: https://elevenlabs.io/app/voice-library
  Model: eleven_multilingual_v2
  """

  @behaviour ArcaneVoice.TTS.Engine

  alias ArcaneVoice.TTS.Audio

  @api_url "https://api.elevenlabs.io/v1/text-to-speech"

  @impl true
  def synthesize(text, voice, opts) do
    api_key = api_key!()
    url = "#{@api_url}/#{voice}"

    body =
      %{
        text: text,
        model_id: opts[:model] || "eleven_multilingual_v2",
        voice_settings: %{
          stability: opts[:stability] || 0.5,
          similarity_boost: opts[:similarity] || 0.75
        }
      }
      |> Jason.encode!()

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"},
      {"Accept", "audio/mpeg"}
    ]

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, ArcaneVoice.Finch) do
      {:ok, %{status: 200, body: mp3_data}} ->
        Audio.to_pcm(mp3_data, "mp3")

      {:ok, %{status: status, body: body}} ->
        {:error, "ElevenLabs returned HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, "ElevenLabs request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def describe_voice(voice), do: "ElevenLabs: #{voice}"

  def default_voice, do: "21m00Tcm4TlvDq8ikWAM"

  defp api_key! do
    System.get_env("ELEVENLABS_API_KEY") ||
      raise "ELEVENLABS_API_KEY is not set"
  end
end
