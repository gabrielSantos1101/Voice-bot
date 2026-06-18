defmodule ArcaneVoice.Api.Router do
  import Plug.Conn

  alias ArcaneVoice.Api.Routes.Discord
  alias ArcaneVoice.Api.Routes.Metrics
  alias ArcaneVoice.Api.Util

  use Plug.Router

  plug(Corsica,
    origins: "*",
    max_age: 600,
    allow_methods: :all,
    allow_headers: :all
  )

  plug(:match)
  plug(:dispatch)
  plug(:metrics_handle)

  def metrics_handle(conn, _opts) do
    stat =
      cond do
        conn.status >= 200 && conn.status < 300 ->
          :arcane_voice_2xx_responses

        conn.status >= 400 && conn.status < 500 ->
          :arcane_voice_4xx_responses

        conn.status >= 500 ->
          :arcane_voice_5xx_responses
      end

    ArcaneVoice.Metrics.Collector.inc(:counter, stat)

    conn
  end

  get "/" do
    send_resp(conn, 200, "ArcaneVoice is running")
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  forward("/discord", to: Discord)
  forward("/metrics", to: Metrics)
  forward("/tts", to: ArcaneVoice.Api.Routes.TTS)
  forward("/debug", to: ArcaneVoice.Api.Routes.Debug)

  options _ do
    conn
    |> send_resp(204, "")
  end

  match _ do
    Util.not_found(conn)
  end
end
