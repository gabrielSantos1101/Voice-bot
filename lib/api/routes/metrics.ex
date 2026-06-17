defmodule ArcaneVoice.Api.Routes.Metrics do
  use Plug.Router

  plug(ArcaneVoice.Metrics.Exporter)

  plug(:match)
  plug(:dispatch)

  match _ do
    send_resp(conn, 404, "Metrics available at /metrics")
  end
end
