defmodule ArcaneVoice.Api.Routes.TTS do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/" do
    {:ok, body, conn} = read_body(conn)
    %{"guild_id" => guild_id, "channel_id" => channel_id, "text" => text} = Jason.decode!(body)

    task = Task.async(fn ->
      ArcaneVoice.TTS.speak(%{text: text, voice_channel_id: channel_id, guild_id: guild_id})
    end)

    case Task.yield(task, 2000) || Task.shutdown(task, :brutal_kill) do
      {:ok, _} ->
        send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
      nil ->
        send_resp(conn, 202, Jason.encode!(%{status: "queued"}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
