defmodule ArcaneVoice.TTS.Session do
  @moduledoc false

  # BUILD_ID: DAVE fixes + binary frame parsing fix (v4 has no seq number)
  @build_id "2026-06-18-dave-v2"

  require Logger

  alias ArcaneVoice.TTS.Opus

  @encryption_modes ["aead_aes256_gcm_rtpsize", "aead_aes256_gcm", "aead_xchacha20_poly1305_rtpsize", "xsalsa20_poly1305", "xsalsa20_poly1305_rtpsize"]

  # WARNING: :chacha20_poly1305 in Erlang is IETF ChaCha20 (12-byte nonce).
  # Discord's aead_xchacha20_poly1305_rtpsize uses XChaCha20 (24-byte nonce via HChaCha20).
  # This mapping is INCORRECT but Erlang's :crypto has no XChaCha20 support.
  # We rely on AES-GCM being preferred/available; if only XChaCha20 is offered, transport
  # encryption will fail. A libsodium NIF is needed to fix this properly.
  @cipher_map %{
    "aead_aes256_gcm_rtpsize" => :aes_256_gcm,
    "aead_aes256_gcm" => :aes_256_gcm,
    "aead_xchacha20_poly1305_rtpsize" => :chacha20_poly1305,
    "xsalsa20_poly1305" => :chacha20_poly1305,
    "xsalsa20_poly1305_rtpsize" => :chacha20_poly1305
  }

  @timeout_ms 60_000

  defstruct ~w[
    guild_id channel_id text bot_user_id
    session_id voice_token voice_endpoint
    voice_ws_pid udp_socket ssrc
    secret_key encryption_mode sequence timestamp
    audio_frames frame_index stream_timer
    discovered_ip discovered_port interaction_token
    voice_ip voice_port tts_pid timeout_timer
    dave_ready dave_initialized dave_active
    dave_key_package_sent first_sent
    encoding_task stream_after_encode
  ]a

  def start_link(opts) do
    guild_id = Keyword.fetch!(opts, :guild_id)
    channel_id = Keyword.fetch!(opts, :channel_id)
    text = Keyword.fetch!(opts, :text)
    interaction_token = Keyword.fetch!(opts, :interaction_token)

    GenServer.start_link(__MODULE__, %__MODULE__{
      guild_id: guild_id,
      channel_id: channel_id,
      text: text,
      interaction_token: interaction_token,
      sequence: 0,
      timestamp: 0,
      dave_ready: false
    })
  end

  @impl true
  def init(state) do
    Logger.info("TTS session started (build=#{@build_id}) for guild #{state.guild_id}, channel #{state.channel_id}")
    send(:discord_bot, {:get_bot_user_id, self()})
    Process.send_after(self(), :fetch_bot_id, 500)
    {:ok, state}
  end

  @impl true
  def handle_info({:tts_config, tts_pid, _guild_id}, state) do
    timer = Process.send_after(self(), :timeout, @timeout_ms)
    {:noreply, %{state | tts_pid: tts_pid, timeout_timer: timer}}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning("Session: timeout for guild #{state.guild_id}")
    notify_ended(state)
    {:stop, :normal, state}
  end

  def handle_info(:fetch_bot_id, state) do
    if is_nil(state.bot_user_id) do
      send(:discord_bot, {:get_bot_user_id, self()})
      Process.send_after(self(), :fetch_bot_id, 500)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:bot_user_id, user_id}, state) do
    state = %{state | bot_user_id: user_id}
    send(:discord_bot, {:voice_state_update, state.guild_id, state.channel_id, false, false})
    {:noreply, state}
  end

  def handle_info({:voice_state, data}, state) do
    if state.bot_user_id && data["user_id"] == state.bot_user_id && data["channel_id"] do
      session_id = data["session_id"]
      Logger.debug("Session: got voice_state session_id=#{session_id}")
      state = %{state | session_id: session_id}

      if state.voice_endpoint && state.voice_token do
        Logger.debug("Session: voice_server data already available, connecting voice WS")
        {:noreply, connect_voice_ws(state)}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:voice_server, data}, state) do
    token = data["token"]
    endpoint_raw = data["endpoint"]
    Logger.info("Session: got voice_server token=#{token} endpoint=#{endpoint_raw}")

    endpoint =
      endpoint_raw
      |> String.replace(":80", "")
      |> String.replace_suffix(".", "")

    state = %{state | voice_endpoint: endpoint, voice_token: token}

    if state.session_id && state.bot_user_id do
      Logger.debug("Session: session_id already available, connecting voice WS")
      {:noreply, connect_voice_ws(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:voice_ready, ssrc, ip, port, modes}, state) do
    Logger.info("Session: voice ready, ssrc=#{ssrc}, modes=#{inspect(modes)}")

    selected_mode = Enum.find(@encryption_modes, &(&1 in modes))

    if selected_mode do
      state = %{state | ssrc: ssrc, voice_ip: ip, voice_port: port, encryption_mode: selected_mode}

      case discover_ip(state) do
        {:ok, state} ->
          send(state.voice_ws_pid, {:select_protocol, state.discovered_ip, state.discovered_port, selected_mode})
          {:noreply, state}

        {:error, reason} ->
          Logger.error("Session: IP discovery failed: #{inspect(reason)}")
          {:stop, :ip_discovery_failed, state}
      end
    else
      Logger.error("Session: no compatible encryption mode in #{inspect(modes)}")
      {:stop, :no_compatible_mode, state}
    end
  end

  def handle_info({:session_description, mode, secret_key, dave_ver}, state) do
    Logger.info("Session: got session description, mode=#{mode}, key_size=#{byte_size(secret_key)}, dave_ver=#{dave_ver}")
    state = %{state | encryption_mode: mode, secret_key: secret_key, dave_active: dave_ver > 0}

    if state.dave_ready || !state.dave_active do
      Logger.info("Session: #{if state.dave_ready, do: "DAVE ready, ", else: "no DAVE, "}starting TTS encoding")
      send(self(), :encode_and_stream)
    else
      Logger.info("Session: waiting for DAVE handshake before starting stream; encoding TTS for debug/cache")
      send(self(), :encode_only)
    end

    {:noreply, state}
  end

  # ── DAVE Handlers ──

  def handle_info({:dave_prepare_epoch, epoch}, state) do
    Logger.info("Session: DAVE prepare_epoch epoch=#{epoch}")
    {:noreply, prepare_dave_epoch(state, epoch)}
  end

  def handle_info({:dave_frame, 25, seq, payload}, state) do
    Logger.info("Session: DAVE external_sender_package (#{byte_size(payload)}b)")
    state = ensure_dave_initialized(state)
    _ = ArcaneVoice.TTS.Dave.handle_external_sender(state.guild_id, payload, dave_seq(seq))
    state = prepare_dave_epoch(state, 1)
    {:noreply, state}
  end

  def handle_info({:dave_frame, 27, seq, payload}, state) do
    Logger.info("Session: DAVE proposals (#{byte_size(payload)}b)")
    state = ensure_dave_initialized(state)

    case ArcaneVoice.TTS.Dave.handle_proposals(state.guild_id, payload, dave_seq(seq)) do
      {:ok, %{opcode: 28, payload: commit_welcome}} ->
        Logger.info("Session: DAVE sending commit_welcome (#{byte_size(commit_welcome)}b)")
        send(state.voice_ws_pid, {:send_dave_binary, 28, commit_welcome})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:dave_frame, 29, _seq, payload}, state) do
    <<transition_id::32, commit::binary>> = payload
    Logger.info("Session: DAVE announce_commit id=#{transition_id} (#{byte_size(commit)}b)")
    _ = ArcaneVoice.TTS.Dave.handle_commit(state.guild_id, transition_id, commit)
    if state.voice_ws_pid do
      Logger.info("Session: DAVE sending transition ready (op 23)")
      send(state.voice_ws_pid, {:send_transition_ready, transition_id})
    end
    {:noreply, state}
  end

  def handle_info({:dave_frame, 30, _seq, payload}, state) do
    <<transition_id::32, welcome::binary>> = payload
    Logger.info("Session: DAVE welcome id=#{transition_id} (#{byte_size(welcome)}b)")
    _ = ArcaneVoice.TTS.Dave.handle_welcome(state.guild_id, transition_id, welcome)
    if state.voice_ws_pid do
      Logger.info("Session: DAVE sending transition ready (op 23)")
      send(state.voice_ws_pid, {:send_transition_ready, transition_id})
    end
    {:noreply, state}
  end

  def handle_info({:dave_frame, opcode, seq, _payload}, state) do
    Logger.debug("Session: DAVE unhandled frame op=#{opcode} seq=#{seq}")
    {:noreply, state}
  end

  def handle_info({:dave_execute_transition, transition_id}, state) do
    Logger.info("Session: DAVE execute_transition id=#{transition_id}")
    _ = ArcaneVoice.TTS.Dave.execute_transition(state.guild_id, transition_id)
    state = %{state | dave_ready: true}

    if state.secret_key do
      Logger.info("Session: DAVE ready, starting stream")
      send(self(), :stream_when_ready)
    else
      Logger.info("Session: DAVE ready, waiting for session description")
    end

    {:noreply, state}
  end

  defp ensure_dave_initialized(state) do
    if state.dave_initialized do
      state
    else
      user_id = String.to_integer(state.bot_user_id)

      case ArcaneVoice.TTS.Dave.init_session(state.guild_id, user_id) do
        :ok -> :ok
        {:ok, _} -> :ok
        other -> Logger.warning("Session: Dave init: #{inspect(other)}")
      end

      %{state | dave_initialized: true}
    end
  end

  defp prepare_dave_epoch(state, epoch) do
    state = ensure_dave_initialized(state)

    if state.dave_key_package_sent do
      Logger.debug("Session: DAVE key_package already sent, skipping epoch=#{epoch}")
      state
    else
      case ArcaneVoice.TTS.Dave.prepare_epoch(state.guild_id, epoch) do
        {:ok, %{opcode: 26, payload: key_package}} ->
          Logger.info("Session: DAVE sending key_package (#{byte_size(key_package)}b)")
          send(state.voice_ws_pid, {:send_dave_binary, 26, key_package})
          %{state | dave_key_package_sent: true}

        other ->
          Logger.warning("Session: Dave prepare_epoch: #{inspect(other)}")
          state
      end
    end
  end

  defp dave_seq(seq) when is_integer(seq), do: seq
  defp dave_seq(_), do: 0

  # ── Streaming ──

  def handle_info(:encode_only, state) do
    {:noreply, maybe_start_encoding(state, false)}
  end

  def handle_info(:encode_and_stream, state) do
    state = maybe_start_encoding(state, true)

    if state.audio_frames do
      send(self(), :stream_when_ready)
    end

    {:noreply, state}
  end

  def handle_info({:tts_encoded, {:ok, frames}}, state) do
    log_encoded_frames(frames)
    state = %{state | audio_frames: frames, encoding_task: nil}

    if state.stream_after_encode do
      send(self(), :stream_when_ready)
      {:noreply, %{state | stream_after_encode: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tts_encoded, {:error, reason}}, state) do
    Logger.error("Session: TTS encoding failed: #{inspect(reason)}")
    {:stop, :tts_failed, %{state | encoding_task: nil}}
  end

  def handle_info({:tts_encoded, other}, state) do
    Logger.error("Session: TTS encoding returned unexpected result: #{inspect(other)}")
    {:stop, :tts_failed, %{state | encoding_task: nil}}
  end

  def handle_info(:stream_when_ready, state) do
    cond do
      is_nil(state.audio_frames) ->
        Logger.info("Session: stream requested before audio is ready; waiting for encoder")
        {:noreply, maybe_start_encoding(%{state | stream_after_encode: true}, true)}

      is_nil(state.voice_ws_pid) ->
        Logger.error("Session: voice_ws_pid is nil, CANNOT send speaking=1")
        {:noreply, state}

      true ->
        Logger.info("Session: SENDING SPEAKING=1 NOW")
        send(state.voice_ws_pid, {:send_speaking, true})
        Process.send_after(self(), :do_stream, 30)
        {:noreply, state}
    end
  end

  def handle_info(:do_stream, state) do
    {:noreply, start_streaming(state)}
  end

  def handle_info({:voice_ws_disconnected}, state) do
    Logger.info("Session: voice WS disconnected")
    {:stop, :normal, state}
  end

  def handle_info(:tick, state) do
    total = length(state.audio_frames)
    if state.frame_index < total do
      Logger.debug("Session: sending frame #{state.frame_index}/#{total}")
      state = send_frame(state)
      timer = Process.send_after(self(), :tick, 20)
      {:noreply, %{state | stream_timer: timer, frame_index: state.frame_index + 1,
                           sequence: state.sequence + 1, timestamp: state.timestamp + 960,
                           first_sent: false}}
    else
      Logger.info("Session: all #{total} frames sent, finishing playback")
      finish_playback(state)
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Session: unhandled #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("TTS session terminated for guild #{state.guild_id}")
    cleanup(state)
    notify_ended(state)
    send(:discord_bot, {:voice_state_update, state.guild_id, nil, false, false})
  end

  defp notify_ended(state) do
    if state.tts_pid, do: send(state.tts_pid, {:session_ended, state.guild_id, self()})
  end

  defp connect_voice_ws(state) do
    {:ok, pid} = ArcaneVoice.TTS.VoiceConnection.start_link(
      self(), state.voice_endpoint,
      state.guild_id, state.bot_user_id,
      state.session_id, state.voice_token
    )
    %{state | voice_ws_pid: pid}
  end

  defp discover_ip(state) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        result = do_discover_ip(socket, state, 0)
        case result do
          {:ok, _} -> result
          {:error, _} -> :gen_udp.close(socket); result
        end

      {:error, reason} ->
        {:error, "socket: #{inspect(reason)}"}
    end
  end

  defp do_discover_ip(socket, state, attempt) do
    # Formato igual ao discord.js: uint16 type=1 + uint16 length=70 + uint32 ssrc + 66 zeros = 74 bytes
    discovery = <<0x00, 0x01, 0x00, 0x46, state.ssrc::32, 0::size(528)>>
    :gen_udp.send(socket, to_charlist(state.voice_ip), state.voice_port, discovery)
    Logger.debug("IP discovery: attempt #{attempt + 1} sent 74b to #{state.voice_ip}:#{state.voice_port}")

    timeout = if attempt == 0, do: 1500, else: 3000

    case :gen_udp.recv(socket, 74, timeout) do
      {:ok, {_addr, _port, packet}} when byte_size(packet) >= 74 ->
        <<_type::16, _length::16, _ssrc::32, ip_bin::binary-size(64), ext_port::16>> = packet
        ip = String.trim_trailing(to_string(ip_bin), <<0>>)
        Logger.debug("IP discovery: response ip=#{ip} port=#{ext_port}")
        {:ok, %{state | udp_socket: socket, discovered_ip: ip, discovered_port: ext_port}}

      {:ok, packet} ->
        :gen_udp.close(socket)
        {:error, "response too short: #{byte_size(packet)}b"}

      {:error, :timeout} when attempt < 2 ->
        Logger.debug("IP discovery: timeout on attempt #{attempt + 1}, retrying...")
        do_discover_ip(socket, state, attempt + 1)

      {:error, reason} ->
        {:error, "recv: #{inspect(reason)}"}
    end
  end

  defp encode_tts(state) do
    engine = ArcaneVoice.TTS.Engine.build(
      provider: Application.get_env(:arcane_voice, :tts_provider, :edge),
      voice: Application.get_env(:arcane_voice, :tts_voice)
    )

    task = Task.async(fn ->
      case ArcaneVoice.TTS.Engine.synthesize(engine, state.text) do
        {:ok, pcm} ->
          pcm_size = byte_size(pcm)
          Logger.info("Session: PCM synthesized, size=#{pcm_size} bytes (#{div(pcm_size, 96000)}s approx)")
          case Opus.encode(pcm) do
            {:ok, frames} ->
              Logger.info("Session: Opus encoded, #{length(frames)} frames")
              {:ok, frames}
            error ->
              Logger.error("Session: Opus encode failed: #{inspect(error)}")
              error
          end
        error ->
          Logger.error("Session: TTS synthesis failed: #{inspect(error)}")
          error
      end
    end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} ->
        Logger.error("Session: TTS synthesis crashed: #{inspect(reason)}")
        {:error, "TTS synthesis crashed"}
      nil ->
        Logger.error("Session: TTS synthesis timed out after 30s")
        {:error, "TTS synthesis timed out"}
    end
  end

  defp maybe_start_encoding(%{audio_frames: frames} = state, stream_after) when not is_nil(frames) do
    %{state | stream_after_encode: state.stream_after_encode || stream_after}
  end

  defp maybe_start_encoding(%{encoding_task: task} = state, stream_after) when not is_nil(task) do
    %{state | stream_after_encode: state.stream_after_encode || stream_after}
  end

  defp maybe_start_encoding(state, stream_after) do
    caller = self()
    text = state.text

    Logger.info(
      "Session: encoding TTS #{if stream_after, do: "for stream", else: "for debug/cache"}: #{String.slice(text, 0, 50)}"
    )

    {:ok, task} =
      Task.start(fn ->
        send(caller, {:tts_encoded, encode_tts(%{state | text: text})})
      end)

    %{state | encoding_task: task, stream_after_encode: stream_after}
  end

  defp log_encoded_frames(frames) do
    total_bytes = Enum.reduce(frames, 0, fn {_ts, frame}, acc -> acc + byte_size(frame) end)
    non_dtx = Enum.count(frames, fn {_ts, frame} -> byte_size(frame) > 3 end)
    first5_sizes = frames |> Enum.take(5) |> Enum.map(fn {_ts, frame} -> byte_size(frame) end) |> inspect()

    Logger.info(
      "Session: encoded #{length(frames)} Opus frames, #{non_dtx} non-DTX, total #{total_bytes}b, " <>
        "avg #{div(total_bytes, max(length(frames), 1))}b, first5: #{first5_sizes}"
    )
  end

  defp start_streaming(state) do
    {:ok, {local_ip, local_port}} = :inet.sockname(state.udp_socket)

    # log first 5 frame sizes to confirm audio data
    first5 = Enum.take(state.audio_frames, 5)
    sized = Enum.map(first5, fn {_ts, f} -> byte_size(f) end)
    non_zero = Enum.count(sized, &(&1 > 3))
    Logger.info("Session: first 5 frame sizes: #{inspect(sized)} (non-DTX: #{non_zero}/5)")

    # skip leading DTX/silence frames (3 bytes = <<0xF8, 0xFF, 0xFE>>)
    first_audio_idx =
      state.audio_frames
      |> Enum.find_index(fn {_ts, frame} -> byte_size(frame) > 3 end)
      || 0

    if first_audio_idx > 0 do
      Logger.info("Session: skipping #{first_audio_idx} leading DTX frames")
    end

    Logger.info("Session STARTING STREAM, #{length(state.audio_frames)} frames (from idx #{first_audio_idx}), " <>
      "socket=#{inspect(local_ip)}:#{local_port}, dest=#{state.voice_ip}:#{state.voice_port}, " <>
      "encryption=#{state.encryption_mode}, ssrc=#{state.ssrc}")

    state = %{state | frame_index: first_audio_idx, timestamp: first_audio_idx * 960, first_sent: true}
    timer = Process.send_after(self(), :tick, 50)
    %{state | stream_timer: timer}
  end

  defp send_frame(state) do
    {_ts, opus_frame} = Enum.at(state.audio_frames, state.frame_index)
    frame_size = byte_size(opus_frame)
    marker_bit = if state.first_sent, do: 1, else: 0
    Logger.debug("Session: send_frame idx=#{state.frame_index} size=#{frame_size} seq=#{state.sequence} ts=#{state.timestamp} marker=#{marker_bit}")
    byte1 = if marker_bit == 1, do: 0xF8, else: 0x78
    header = <<0x80, byte1, state.sequence::16-big, state.timestamp::32-big, state.ssrc::32-big>>

    packet = cond do
      state.dave_active && state.dave_ready ->
        case ArcaneVoice.TTS.Dave.encrypt_frame(state.guild_id, opus_frame, "OPUS") do
          {:ok, %{payload: encrypted}} ->
            Logger.debug("Session: DAVE encrypt produced #{byte_size(encrypted)}b frame")
            cipher = @cipher_map[state.encryption_mode] || :aes_256_gcm
            n4 = <<state.sequence::32-big>>
            nonce_12byte = transport_nonce(n4)
            Logger.debug("Session: DAVE encrypt OTP27 arg4=encrypted(#{byte_size(encrypted)}b) arg5=header(#{byte_size(header)}b)")
            {ciphertext, tag} = :crypto.crypto_one_time_aead(
              cipher, state.secret_key, nonce_12byte, encrypted, header, true
            )
            pkt = if String.ends_with?(state.encryption_mode, "_rtpsize") do
              header <> ciphertext <> tag <> n4
            else
              header <> ciphertext <> tag
            end
            if state.first_sent do
              Logger.info("Session: FIRST DAVE packet nonce=#{Base.encode16(nonce_12byte)} ct=#{byte_size(ciphertext)}")
            end
            pkt
          {:error, reason} ->
            Logger.warning("Session: DAVE encrypt failed: #{inspect(reason)}")
            nil
        end

      state.secret_key ->
        cipher = @cipher_map[state.encryption_mode] || :aes_256_gcm
        n4 = <<state.sequence::32-big>>
        nonce_12byte = transport_nonce(n4)
        Logger.info("Session: encrypt OTP27_ORDER arg4=opus_frame(#{byte_size(opus_frame)}b) arg5=header(#{byte_size(header)}b) nonce=#{Base.encode16(nonce_12byte)}")
        {ciphertext, tag} = :crypto.crypto_one_time_aead(
          cipher, state.secret_key, nonce_12byte, opus_frame, header, true
        )
        Logger.info("Session: encrypt RESULT ct=#{byte_size(ciphertext)}b tag=#{byte_size(tag)}b")

        pkt = if String.ends_with?(state.encryption_mode, "_rtpsize") do
          header <> ciphertext <> tag <> n4
        else
          header <> ciphertext <> tag
        end
        if state.sequence == 0 do
          Logger.info("Session: FIRST PACKET hex=#{Base.encode16(header)} #{Base.encode16(ciphertext)} #{Base.encode16(tag)} #{Base.encode16(n4)} full=#{Base.encode16(pkt)}")
        end
        if rem(state.frame_index, 50) == 0 do
          Logger.info("Session: frame #{state.frame_index} seq=#{state.sequence} ts=#{state.timestamp} " <>
            "nonce=#{Base.encode16(nonce_12byte)} aad=#{byte_size(header)}b pt=#{byte_size(opus_frame)}b ct=#{byte_size(ciphertext)}b pkt=#{byte_size(pkt)}b")
        end
        pkt

      true ->
        Logger.error("Session: no encryption available, cannot send frame")
        nil
    end

    if packet do
      case :gen_udp.send(state.udp_socket, to_charlist(state.voice_ip), state.voice_port, packet) do
        :ok -> if state.first_sent, do: Logger.info("Session: first frame UDP OK")
        {:error, reason} -> Logger.error("Session: UDP send failed: #{inspect(reason)}")
      end
    end

    state
  end

  defp finish_playback(state) do
    Logger.info("Session: TTS playback finished in guild #{state.guild_id}")
    if state.voice_ws_pid, do: send(state.voice_ws_pid, {:send_speaking, false})
    Process.send_after(self(), :cleanup_timeout, 300)
    {:stop, :normal, state}
  end

  defp cleanup(state) do
    if state.timeout_timer, do: Process.cancel_timer(state.timeout_timer)
    if state.stream_timer, do: Process.cancel_timer(state.stream_timer)
    if state.udp_socket, do: :gen_udp.close(state.udp_socket)
    if state.voice_ws_pid, do: send(state.voice_ws_pid, :disconnect)
    if state.dave_ready, do: ArcaneVoice.TTS.Dave.close(state.guild_id)
  end

  defp transport_nonce(n4), do: <<n4::binary, 0::size(64)>>
end
