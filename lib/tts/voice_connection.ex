defmodule ArcaneVoice.TTS.VoiceConnection do
  @moduledoc false

  require Logger

  # DAVE opcodes
  @dave_prepare_epoch 24
  @dave_execute_transition 22
  @dave_binary_opcodes 22..31

  def start_link(session_pid, endpoint, guild_id, user_id, session_id, token) do
    url = "wss://#{endpoint}/?v=8"

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
      dave_seq: 0,
      dave_out_seq: 0
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

  def websocket_handle({:text, payload}, _ws_req, state) do
    case Jason.decode(payload) do
      {:ok, %{"op" => 8, "d" => data}} ->
        handle_hello(data, remember_seq(payload, state))

      {:ok, %{"op" => op, "d" => data}} ->
        handle_text_op(op, data, remember_seq(payload, state))

      {:error, _} ->
        Logger.warning("Voice WS: decode error: #{payload}")
        {:ok, state}
    end
  end

  def websocket_handle({:binary, payload}, _ws_req, state) do
    case parse_dave_binary(payload) do
      {:ok, seq, opcode, rest} ->
        Logger.debug("Voice WS: binary frame op=#{opcode} seq=#{inspect(seq)} size=#{byte_size(payload)}b")
        send(state.session_pid, {:dave_frame, opcode, seq, rest})
        state = if is_integer(seq), do: %{state | dave_seq: seq}, else: state
        state = %{state | dave_active: true}

        if is_integer(seq) do
          {:reply, {:text, heartbeat_payload(state)}, state}
        else
          {:ok, state}
        end

      :error ->
        Logger.warning("Voice WS: binary frame too short: #{byte_size(payload)}b")
        {:ok, state}
    end
  end

  def websocket_info({:select_protocol, ip, port, mode}, _ws_req, state) do
    payload = Jason.encode!(%{
      op: 1,
      d: %{protocol: "udp", data: %{address: ip, port: port, mode: mode}}
    })
    {:reply, {:text, payload}, state}
  end

  def websocket_info(:heartbeat_tick, _ws_req, state) do
    timer = Process.send_after(self(), :heartbeat_tick, state.heartbeat_interval)
    {:reply, {:text, heartbeat_payload(state)}, %{state | heartbeat_timer: timer}}
  end

  def websocket_info(:disconnect, _ws_req, state) do
    {:close, "disconnect", state}
  end

  def websocket_info({:send_speaking, speaking}, _ws_req, state) do
    speaking_val = if speaking, do: 1, else: 0
    payload = Jason.encode!(%{
      op: 5,
      d: %{speaking: speaking_val, delay: 0, ssrc: state.ssrc}
    })
    Logger.debug("Voice WS: sending speaking=#{speaking_val}")
    {:reply, {:text, payload}, state}
  end

  def websocket_info({:send_dave_binary, opcode, payload}, _ws_req, state) do
    seq = state.dave_out_seq + 1
    frame = <<seq::16-big, opcode::8, payload::binary>>
    Logger.debug(
      "Voice WS: sending dave binary op=#{opcode} seq=#{seq} size=#{byte_size(frame)}b head=#{frame_head(frame)}"
    )
    {:reply, {:binary, frame}, %{state | dave_out_seq: seq}}
  end

  def websocket_info({:send_transition_ready, transition_id}, _ws_req, state) do
    payload = Jason.encode!(%{
      op: 23,
      d: %{transition_id: transition_id}
    })

    Logger.debug("Voice WS: sending DAVE transition ready id=#{transition_id}")
    {:reply, {:text, payload}, state}
  end

  def websocket_info(_msg, _ws_req, state) do
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

  defp frame_head(frame) do
    size = min(byte_size(frame), 8)
    Base.encode16(binary_part(frame, 0, size), case: :lower)
  end

  defp parse_dave_binary(<<seq::16-big, opcode::8, rest::binary>>) when opcode in @dave_binary_opcodes do
    {:ok, seq, opcode, rest}
  end

  defp parse_dave_binary(<<opcode::8, rest::binary>>) when opcode in @dave_binary_opcodes do
    {:ok, nil, opcode, rest}
  end

  defp parse_dave_binary(_), do: :error

  defp remember_seq(payload, state) do
    case Jason.decode(payload) do
      {:ok, %{"seq" => seq}} when is_integer(seq) -> %{state | dave_seq: seq}
      _ -> state
    end
  end

  defp heartbeat_payload(state) do
    Jason.encode!(%{op: 3, d: %{t: System.system_time(:millisecond), seq_ack: state.dave_seq}})
  end
end
