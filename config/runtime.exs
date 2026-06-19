import Config

if config_env() == :prod do
  config :arcane_voice,
    http_port: String.to_integer(System.get_env("PORT") || "4001"),
    bot_presence: System.get_env("BOT_PRESENCE") || "voice",
    bot_presence_type: String.to_integer(System.get_env("BOT_PRESENCE_TYPE") || "3"),
    bot_token: System.get_env("BOT_TOKEN")
end
