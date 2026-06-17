defmodule ArcaneVoice.TTS.Engine.OpenAI do
  @moduledoc """
  TTS provider using OpenAI's TTS API (tts-1 / tts-1-hd).

  Requires OPENAI_API_KEY env var.

  Voices: alloy, echo, fable, nova, shimmer, coral
  Model: tts-1 (lowest latency) or tts-1-hd (higher quality)
  """

  @behaviour ArcaneVoice.TTS.Engine

  alias ArcaneVoice.TTS.Audio

  @api_url "https://api.openai.com/v1/audio/speech"

  @impl true
  def synthesize(text, voice, opts) do
    api_key = api_key!()
    model = opts[:model] || "tts-1"

    body =
      %{
        model: model,
        input: text,
        voice: voice,
        response_format: "opus",
        speed: opts[:speed] || 1.0
      }
      |> Jason.encode!()

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:post, @api_url, headers, body)

    case Finch.request(request, ArcaneVoice.Finch) do
      {:ok, %{status: 200, body: opus_data}} ->
        Audio.to_pcm(opus_data, "opus")

      {:ok, %{status: status, body: body}} ->
        {:error, "OpenAI TTS returned HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, "OpenAI TTS request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def describe_voice(voice) do
    descriptions = %{
      "alloy" => "OpenAI Alloy (neutral, versatile)",
      "echo" => "OpenAI Echo (warm, male)",
      "fable" => "OpenAI Fable (British, storytelling)",
      "nova" => "OpenAI Nova (female, warm)",
      "shimmer" => "OpenAI Shimmer (female, clear)",
      "coral" => "OpenAI Coral (female, energetic)"
    }

    Map.get(descriptions, voice, "OpenAI: #{voice}")
  end

  defp api_key! do
    System.get_env("OPENAI_API_KEY") ||
      raise "OPENAI_API_KEY is not set"
  end

  def default_voice, do: "nova"
end
