defmodule ArcaneVoice do
  require Logger
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    :ets.new(:cached_presences, [:named_table, :set, :public])
    :ets.new(:global_subscribers, [:named_table, :set, :public])

    children = [
      {Finch, name: ArcaneVoice.Finch},
      {GenRegistry, worker_module: ArcaneVoice.Presence},
      {ArcaneVoice.Metrics, :normal},
      {ArcaneVoice.Connectivity.Redis, []},
      {ArcaneVoice.TTS, []},
      {ArcaneVoice.DiscordBot, %{token: Application.get_env(:arcane_voice, :bot_token)}},
      {Bandit,
       plug: ArcaneVoice.Api.Router, scheme: :http, port: Application.get_env(:arcane_voice, :http_port)}
    ]

    opts = [strategy: :one_for_one, name: ArcaneVoice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def is_idempotent?() do
    case System.get_env("BOT_IDEMPOTENCY_ENV_KEY") do
      nil ->
        true

      "" ->
        true

      key ->
        case String.split(key, "=", parts: 2, trim: true) do
          [env_key, expected_value] ->
            System.get_env(env_key) == expected_value

          _ ->
            false
        end
    end
  end
end
