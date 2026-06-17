import Config

if config_env() == :prod do
  config :arcane_voice,
    http_port: String.to_integer(System.get_env("PORT") || "4001"),
    bot_presence: System.get_env("BOT_PRESENCE") || "voice",
    bot_presence_type: String.to_integer(System.get_env("BOT_PRESENCE_TYPE") || "3"),
    bot_token: System.get_env("BOT_TOKEN"),
    redis_uri:
      System.get_env("REDIS_DSN") || System.get_env("REDIS_URI") || System.get_env("REDIS_URL"),
    is_idempotent: ArcaneVoice.is_idempotent?(),
    external_url: System.get_env("EXTERNAL_URL") || "https://api.arcanevoice.rest",
    tts_provider: String.to_atom(System.get_env("TTS_PROVIDER") || "edge"),
    tts_voice: System.get_env("TTS_VOICE")
end
