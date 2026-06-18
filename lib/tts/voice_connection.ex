defmodule ArcaneVoice.TTS.VoiceConnection do
  @moduledoc false

  require Logger

  # DAVE opcodes
  @dave_prepare_epoch 24
  @dave_execute_transition 22

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
      ssrc: nil,
      dave_active: false,
      dave_seq: 0
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
    case Jason.decode(payload) do
      {:ok, %{"op" => 8, "d" => data}} ->
        handle_hello(data, state)

      {:ok, %{"op" => op, "d" => data}} ->
        handle_text_op(op, data, state)

      {:error, _} ->
        Logger.warning("Voice WS: decode error: #{payload}")
        {:ok, state}
    end
  end

  def websocket_handle({:binary, payload}, ws_req, state) do
    # Voice gateway v4: binary frames are <opcode::8, payload::binary> (no sequence number)
    if byte_size(payload) >= 1 do
      <<opcode::8, rest::binary>> = payload
      Logger.debug("Voice WS: binary frame op=#{opcode} size=#{byte_size(payload)}b")
      send(state.session_pid, {:dave_frame, opcode, 0, rest})
      {:ok, %{state | dave_active: true}}
    else
      Logger.warning("Voice WS: binary frame too short: #{byte_size(payload)}b")
      {:ok, state}
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
    speaking_val = if speaking, do: 1, else: 0
    payload = Jason.encode!(%{
      op: 5,
      d: %{speaking: speaking_val, delay: 0, ssrc: state.ssrc}
    })
    Logger.debug("Voice WS: sending speaking=#{speaking_val}")
    {:reply, {:text, payload}, state}
  end

  def websocket_info({:send_dave_binary, opcode, payload}, ws_req, state) do
    frame = <<opcode::8, payload::binary>>
    Logger.debug("Voice WS: sending dave binary op=#{opcode} size=#{byte_size(frame)}b")
    {:reply, {:binary, frame}, state}
  end

  def websocket_info({:send_transition_ready, transition_id}, ws_req, state) do
    payload = Jason.encode!(%{
      op: 23,
      d: %{transition_id: transition_id}
    })

    Logger.debug("Voice WS: sending DAVE transition ready id=#{transition_id}")
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

  defp handle_hello(data, state) do
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
  end

  defp handle_text_op(2, data, state) do
    Logger.debug("Voice WS: Ready received")
    send(state.session_pid, {:voice_ready, data["ssrc"], data["ip"], data["port"], data["modes"]})
    {:ok, %{state | ssrc: data["ssrc"]}}
  end

  defp handle_text_op(4, data, state) do
    key = :binary.list_to_bin(data["secret_key"])
    dave_ver = data["dave_protocol_version"] || 0
    Logger.info("Voice WS: Session Description mode=#{data["mode"]} dave_protocol_version=#{dave_ver}")
    send(state.session_pid, {:session_description, data["mode"], key, dave_ver})
    {:ok, state}
  end

  defp handle_text_op(6, _data, state) do
    {:ok, state}
  end

  defp handle_text_op(@dave_prepare_epoch, data, state) do
    Logger.info("Voice WS: DAVE prepare_epoch version=#{data["protocol_version"]} epoch=#{data["epoch"]}")
    send(state.session_pid, {:dave_prepare_epoch, data["epoch"]})
    {:ok, state}
  end

  defp handle_text_op(@dave_execute_transition, data, state) do
    Logger.info("Voice WS: DAVE execute_transition id=#{data["transition_id"]}")
    send(state.session_pid, {:dave_execute_transition, data["transition_id"]})
    {:ok, state}
  end

  defp handle_text_op(_op, _data, state) do
    {:ok, state}
  end
end
