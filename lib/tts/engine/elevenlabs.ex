defmodule ArcaneVoice.TTS.Engine.ElevenLabs do
  @moduledoc """
  TTS provider using ElevenLabs API.

  Requires ELEVENLABS_API_KEY env var.

  Uses Eleven Multilingual v2 model.
  Voice IDs are UUIDs from the ElevenLabs Voice Library.
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
        model_id: "eleven_multilingual_v2",
        output_format: "mp3_44100_128"
      }
      |> Jason.encode!()

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, ArcaneVoice.Finch) do
      {:ok, %{status: 200, body: mp3_data}} ->
        Audio.to_pcm(mp3_data, "mp3")

      {:ok, %{status: status, body: body}} ->
        {:error, "ElevenLabs TTS returned HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, "ElevenLabs TTS request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def describe_voice(voice) do
    "ElevenLabs: #{voice}"
  end

  defp api_key! do
    System.get_env("ELEVENLABS_API_KEY") ||
      raise "ELEVENLABS_API_KEY is not set"
  end

  def default_voice, do: "YbP0Eq5RE5uOoCEl7F3T"
end
