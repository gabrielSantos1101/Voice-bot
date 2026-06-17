defmodule ArcaneVoice.TTS.Engine do
  @moduledoc """
  Abstraction for Text-to-Speech providers.

  Implementations must return raw PCM s16le 48kHz mono audio
  (the format Discord voice expects before Opus encoding).
  """

  @callback synthesize(text :: String.t(), voice :: String.t(), opts :: keyword()) ::
              {:ok, pcm_binary :: binary()} | {:error, term()}

  @callback describe_voice(voice :: String.t()) :: String.t()

  defstruct [:provider, :voice, :opts]

  def build(opts \\ []) do
    provider = opts[:provider] || configured_provider()
    voice = opts[:voice]
    provider_opts = Keyword.drop(opts, [:provider, :voice])

    impl = impl_for(provider)

    voice =
      voice ||
        Application.get_env(:arcane_voice, :tts_voice, impl.default_voice())

    struct!(__MODULE__, provider: provider, voice: voice, opts: provider_opts)
  end

  def synthesize(%__MODULE__{} = engine, text) do
    impl_for(engine.provider).synthesize(text, engine.voice, engine.opts)
  end

  def describe_voice(%__MODULE__{} = engine) do
    impl_for(engine.provider).describe_voice(engine.voice)
  end

  defp impl_for(:edge), do: ArcaneVoice.TTS.Engine.Edge
  defp impl_for(:openai), do: ArcaneVoice.TTS.Engine.OpenAI
  defp impl_for(:elevenlabs), do: ArcaneVoice.TTS.Engine.ElevenLabs

  defp configured_provider do
    Application.get_env(:arcane_voice, :tts_provider, :edge)
  end
end
