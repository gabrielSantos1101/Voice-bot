defmodule ArcaneVoice.TTS.VoiceConnection do
  @moduledoc false

  require Logger

  def start_link(session_pid, endpoint, guild_id, user_id, session_id, token) do
    url = "wss://#{endpoint}/?v=4"

    state = %{
      session_pid: session_pid,
      guild_id: guild_id,
      user_id: user_id,
      session_id: session_id,
      token: token,
      heartbeat_timer: nil,
      heartbeat_interval: nil,
      ssrc: nil
    }

    :websocket_client.start_link(url, __MODULE__, [state])
  end

  def init([state]) do
    {:once, state}
  end

  def onconnect(_ws_req, state) do
    Logger.debug("Voice WS: connected")
    {:ok, state}
  end

  def websocket_handle({:text, payload}, ws_req, state) do
    Logger.debug("Voice WS: text frame: #{payload}")

    case Jason.decode(payload) do
      {:ok, %{"op" => 8, "d" => data}} ->
        interval = data["heartbeat_interval"] |> trunc()
        Logger.debug("Voice WS: Hello, heartbeat every #{interval}ms")

        identify = Jason.encode!(%{
          op: 0,
          d: %{
            server_id: state.guild_id,
            user_id: state.user_id,
            session_id: state.session_id,
            token: state.token,
            max_dave_protocol_version: 1
          }
        })

        timer = Process.send_after(self(), :heartbeat_tick, interval)
        {:reply, {:text, identify}, %{state | heartbeat_interval: interval, heartbeat_timer: timer}}

      {:ok, %{"op" => op, "d" => data}} ->
        handle_op(op, data, state)

      {:ok, _} ->
        {:ok, state}

      {:error, _} ->
        Logger.warning("Voice WS: decode error: #{payload}")
        {:ok, state}
    end
  end

  def websocket_handle({:binary, payload}, ws_req, state) do
    Logger.debug("Voice WS: binary frame #{byte_size(payload)}b")
    case Jason.decode(payload) do
      {:ok, %{"op" => op, "d" => data}} -> handle_op(op, data, state)
      _ -> {:ok, state}
    end
  end

  def websocket_info({:select_protocol, ip, port, mode}, ws_req, state) do
    payload = Jason.encode!(%{
      op: 1,
      d: %{protocol: "udp", data: %{address: ip, port: port, mode: mode}}
    })
    {:reply, {:text, payload}, state}
  end

  def websocket_info(:heartbeat_tick, ws_req, state) do
    nonce = System.system_time(:millisecond)
    payload = Jason.encode!(%{op: 3, d: nonce})
    timer = Process.send_after(self(), :heartbeat_tick, state.heartbeat_interval)
    {:reply, {:text, payload}, %{state | heartbeat_timer: timer}}
  end

  def websocket_info(:disconnect, _ws_req, state) do
    {:close, "disconnect", state}
  end

  def websocket_info({:send_speaking, speaking}, ws_req, state) do
    payload = Jason.encode!(%{
      op: 5,
      d: %{speaking: speaking, delay: 0, ssrc: state.ssrc}
    })
    {:reply, {:text, payload}, state}
  end

  def websocket_info(msg, _ws_req, state) do
    {:ok, state}
  end

  def ondisconnect(_reason, state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    send(state.session_pid, {:voice_ws_disconnected})
    {:close, :normal, state}
  end

  def websocket_terminate(_reason, _conn, _state), do: :ok

  defp handle_op(2, data, state) do
    Logger.debug("Voice WS: Ready received")
    send(state.session_pid, {:voice_ready, data["ssrc"], data["ip"], data["port"], data["modes"]})
    {:ok, %{state | ssrc: data["ssrc"]}}
  end

  defp handle_op(4, data, state) do
    key = :binary.list_to_bin(data["secret_key"])
    send(state.session_pid, {:session_description, data["mode"], key})
    {:ok, state}
  end

  defp handle_op(6, _data, state) do
    {:ok, state}
  end

  defp handle_op(_op, _data, state) do
    {:ok, state}
  end
end
