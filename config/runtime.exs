import Config

provider = System.get_env("TTS_PROVIDER") || "edge"

default_voice = case provider do
  "elevenlabs" -> "21m00Tcm4TlvDq8ikWAM"
  _ -> "pt-BR-FranciscaNeural"
end

config :arcane_voice,
  http_port: String.to_integer(System.get_env("PORT") || "4001"),
  bot_presence: System.get_env("BOT_PRESENCE") || "voice",
  bot_presence_type: String.to_integer(System.get_env("BOT_PRESENCE_TYPE") || "3"),
  bot_token: System.get_env("BOT_TOKEN"),
  tts_provider: String.to_existing_atom(provider),
  tts_voice: System.get_env("TTS_VOICE") || default_voice
