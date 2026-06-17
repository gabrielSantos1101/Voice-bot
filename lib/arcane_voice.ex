defmodule ArcaneVoice do
  require Logger
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      {Finch, name: ArcaneVoice.Finch},
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
end
