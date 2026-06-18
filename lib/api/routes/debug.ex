defmodule ArcaneVoice.Api.Routes.Debug do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    files = ArcaneVoice.Debug.all()
    html = """
    <html><body>
      <h1>ArcaneVoice Debug</h1>
      <ul>
        #{for {key, path} <- files, into: "" do
          name = Path.basename(path)
          "<li><a href=\"/debug/file/#{name}\">#{key}: #{name}</a></li>"
        end}
        #{if files == %{}, do: "<li>No files yet - run /tts first</li>"}
      </ul>
    </body></html>
    """
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  get "/file/:name" do
    files = ArcaneVoice.Debug.all()
    path = Enum.find_value(files, fn {_key, p} ->
      if Path.basename(p) == name, do: p
    end)

    if path && File.exists?(path) do
      ext = Path.extname(path)
      mime = case ext do
        ".mp3" -> "audio/mpeg"
        ".pcm" -> "application/octet-stream"
        ".opus" -> "audio/ogg"
        _ -> "application/octet-stream"
      end
      data = File.read!(path)
      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("content-disposition", "attachment; filename=\"#{name}\"")
      |> send_resp(200, data)
    else
      send_resp(conn, 404, "file not found")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end