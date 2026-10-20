defmodule ArcaneVoice.TTS.Engine.Azure do
  @moduledoc """
  TTS provider using Microsoft Azure Cognitive Services Speech.

  Requires AZURE_SPEECH_KEY and AZURE_SPEECH_REGION env vars.

  Voices: https://learn.microsoft.com/azure/ai-services/speech-service/language-support
  """

  @behaviour ArcaneVoice.TTS.Engine

  alias ArcaneVoice.TTS.Audio

  @api_url "https://%{region}.tts.speech.microsoft.com/cognitiveservices/v1"

  @impl true
  def synthesize(text, voice, opts) do
    api_key = api_key!()
    region = region!()

    url = String.replace(@api_url, "%{region}", region)

    ssml = build_ssml(text, voice, opts[:rate], opts[:pitch])

    headers = [
      {"Ocp-Apim-Subscription-Key", api_key},
      {"Content-Type", "application/ssml+xml"},
      {"X-Microsoft-OutputFormat", "audio-16khz-32kbitrate-mono-mp3"},
      {"User-Agent", "ArcaneVoice"}
    ]

    request = Finch.build(:post, url, headers, ssml)

    case Finch.request(request, ArcaneVoice.Finch) do
      {:ok, %{status: 200, body: mp3_data}} ->
        Audio.to_pcm(mp3_data, "mp3")

      {:ok, %{status: status, body: body}} ->
        {:error, "Azure TTS returned HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, "Azure TTS request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def describe_voice(voice) do
    "Azure Neural: #{voice}"
  end

  defp build_ssml(text, voice, rate, pitch) do
    rate_attr = if rate, do: " rate='#{rate}%'", else: ""
    pitch_attr = if pitch, do: " pitch='#{pitch}Hz'", else: ""

    """
    <speak version='1.0' xml:lang='#{voice_lang(voice)}'>
      <voice xml:lang='#{voice_lang(voice)}' name='#{voice}'#{rate_attr}#{pitch_attr}>
        #{xml_escape(text)}
      </voice>
    </speak>
    """
  end

  defp voice_lang(voice) do
    case voice do
      "pt-BR-" <> _ -> "pt-BR"
      "pt-PT-" <> _ -> "pt-PT"
      "en-US-" <> _ -> "en-US"
      "en-GB-" <> _ -> "en-GB"
      "es-ES-" <> _ -> "es-ES"
      "es-MX-" <> _ -> "es-MX"
      "fr-FR-" <> _ -> "fr-FR"
      "fr-CA-" <> _ -> "fr-CA"
      "de-DE-" <> _ -> "de-DE"
      "it-IT-" <> _ -> "it-IT"
      "ja-JP-" <> _ -> "ja-JP"
      "ko-KR-" <> _ -> "ko-KR"
      "zh-CN-" <> _ -> "zh-CN"
      _ -> "pt-BR"
    end
  end

  defp xml_escape(text) do
    text
    |> String.replace("&", "&")
    |> String.replace("<", "<")
    |> String.replace(">", ">")
    |> String.replace("\"", """)
    |> String.replace("'", "&apos;")
  end

  defp api_key! do
    System.get_env("AZURE_SPEECH_KEY") ||
      raise "AZURE_SPEECH_KEY is not set"
  end

  defp region! do
    System.get_env("AZURE_SPEECH_REGION") ||
      raise "AZURE_SPEECH_REGION is not set"
  end

  def default_voice, do: "pt-BR-FranciscaNeural"
end