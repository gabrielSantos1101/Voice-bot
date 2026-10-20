defmodule ArcaneVoice.TTS.Engine.Google do
  @moduledoc """
  TTS provider using Google Cloud Text-to-Speech API.

  Requires GOOGLE_CLOUD_API_KEY env var (API key from Google Cloud Console).
  Free tier: 1M chars/month (WaveNet/Neural2) - perpetual

  Voices: https://cloud.google.com/text-to-speech/docs/voices
  """

  @behaviour ArcaneVoice.TTS.Engine

  alias ArcaneVoice.TTS.Audio

  @api_url "https://texttospeech.googleapis.com/v1/text:synthesize"

  @impl true
  def synthesize(text, voice, opts) do
    api_key = api_key!()

    voice_parts = String.split(voice, "-")
    language_code = Enum.take(voice_parts, 2) |> Enum.join("-")

    body =
      %{
        input: %{text: text},
        voice: %{
          languageCode: language_code,
          name: voice
        },
        audioConfig: %{
          audioEncoding: "MP3",
          speakingRate: opts[:speed] || 1.0,
          pitch: opts[:pitch] || 0.0,
          sampleRateHertz: 24000
        }
      }
      |> Jason.encode!()

    url = "#{@api_url}?key=#{api_key}"

    headers = [
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, ArcaneVoice.Finch) do
      {:ok, %{status: 200, body: %{"audioContent" => base64_audio}}} ->
        mp3_data = Base.decode64!(base64_audio)
        Audio.to_pcm(mp3_data, "mp3")

      {:ok, %{status: 429, body: body}} ->
        {:error, {:quota_exceeded, parse_quota_error(body, "Google Cloud TTS")}}

      {:ok, %{status: 403, body: body}} ->
        {:error, {:quota_exceeded, parse_quota_error(body, "Google Cloud TTS")}}

      {:ok, %{status: status, body: body}} ->
        {:error, "Google TTS returned HTTP #{status}: #{Jason.encode!(body)}"}

      {:error, reason} ->
        {:error, "Google TTS request failed: #{inspect(reason)}"}
    end
  end

  defp parse_quota_error(body, provider) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) ->
        "#{provider}: #{msg}"
      {:ok, %{"error" => %{"details" => details}}} when is_list(details) ->
        msg = Enum.find_value(details, fn
          %{"@type" => t, "reason" => r} when t == "type.googleapis.com/google.rpc.QuotaFailure" ->
            r
          %{"reason" => r} -> r
          _ -> nil
        end)
        "#{provider}: #{msg || "Limite de quota excedido (1M chars/mês grátis)"}"
      _ ->
        "#{provider}: Limite de caracteres gratuito excedido (1M chars/mês). Configure billing em https://console.cloud.google.com/"
    end
  end

  @impl true
  def describe_voice(voice) do
    "Google Neural2: #{voice}"
  end

  defp api_key! do
    System.get_env("GOOGLE_CLOUD_API_KEY") ||
      raise "GOOGLE_CLOUD_API_KEY is not set"
  end

  def default_voice, do: "pt-BR-Neural2-A"
end