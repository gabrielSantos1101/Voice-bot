defmodule ArcaneVoice.TTS.Engine.PlayHT do
  @moduledoc """
  TTS provider using PlayHT API.

  Requires PLAYHT_API_KEY and PLAYHT_USER_ID env vars.
  Free tier: 12,500 chars/month (no credit card required for signup)

  Voices: https://docs.playht.com/reference/voice-list
  """

  @behaviour ArcaneVoice.TTS.Engine

  alias ArcaneVoice.TTS.Audio

  @api_url "https://api.play.ht/api/v2/tts"

  @impl true
  def synthesize(text, voice, opts) do
    api_key = api_key!()
    user_id = user_id!()

    body =
      %{
        text: text,
        voice: voice,
        voice_engine: opts[:engine] || "PlayHT2.0",
        output_format: "mp3",
        speed: opts[:speed] || 1.0,
        sample_rate: 24000
      }
      |> Jason.encode!()

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"X-User-ID", user_id},
      {"Content-Type", "application/json"},
      {"Accept", "audio/mpeg"}
    ]

    request = Finch.build(:post, @api_url, headers, body)

    case Finch.request(request, ArcaneVoice.Finch) do
      {:ok, %{status: 200, body: mp3_data}} ->
        Audio.to_pcm(mp3_data, "mp3")

      {:ok, %{status: 429, body: body}} ->
        {:error, {:quota_exceeded, parse_quota_error(body, "PlayHT")}}

      {:ok, %{status: 402, body: body}} ->
        {:error, {:quota_exceeded, parse_quota_error(body, "PlayHT")}}

      {:ok, %{status: status, body: body}} ->
        {:error, "PlayHT TTS returned HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, "PlayHT TTS request failed: #{inspect(reason)}"}
    end
  end

  defp parse_quota_error(body, provider) do
    case Jason.decode(body) do
      {:ok, %{"message" => msg}} when is_binary(msg) ->
        "#{provider}: #{msg}"
      {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) ->
        "#{provider}: #{msg}"
      {:ok, %{"detail" => msg}} when is_binary(msg) ->
        "#{provider}: #{msg}"
      _ ->
        "#{provider}: Limite de caracteres gratuito excedido. Configure sua API key em https://play.ht/"
    end
  end

  @impl true
  def describe_voice(voice) do
    "PlayHT: #{voice}"
  end

  defp api_key! do
    System.get_env("PLAYHT_API_KEY") ||
      raise "PLAYHT_API_KEY is not set"
  end

  defp user_id! do
    System.get_env("PLAYHT_USER_ID") ||
      raise "PLAYHT_USER_ID is not set"
  end

  def default_voice, do: "pt-BR-Fabiana"
end