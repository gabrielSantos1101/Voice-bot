# ArcaneStack TTS — Discord Text-to-Speech

## Flow

```
User sends /tts <text>
         │
         ▼
    TTS.handle_interaction/1
         │  ── finds user's voice channel
         │  ── enqueues (if session active) or creates Session
         ▼
    TTS.Session
         │  init/1
         │    ── requests bot_user_id via :discord_bot
         │    ── receives bot_user_id → sends voice_state_update (op 4) to join channel
         │    ── receives voice_state (session_id) + voice_server (token, endpoint)
         ▼
    TTS.VoiceConnection   (websocket_client 1.6.1)
         │  connects wss://<endpoint>/?v=8
         │  receives Hello (op 8, heartbeat_interval)
         │  sends Identify (op 0) with max_dave_protocol_version: 1
         │  receives Ready (op 2) → ssrc, ip, port, modes
         ▼
    TTS.Session
         │  discover_ip/1 — UDP discovery (Type+Length+SSRC big-endian)
         │  sends Select Protocol (op 1) via VoiceConnection
         │  receives Session Description (op 4) → secret_key, dave_ver
         ▼
    DAVE Handshake (E2EE)
         │  On Session Description (op 4):
         │    └─ calls davey.get_serialized_key_package()
         │    └─ sends DAVE key_package (op 26) via voice WS
         │  On op 25 (external_sender):
         │    └─ calls davey.set_external_sender()
         │  On op 27 (proposals):
         │    └─ calls davey.process_proposals()
         │    └─ if commit returned: sends op 23 (transition_ready)
         │  On op 29 (announce_commit):
         │    └─ parses <<transition_id::16, commit::binary>>
         │    └─ calls davey.process_commit(commit)
         │    └─ sends op 23 (transition_ready)
         │  On op 30 (welcome):
         │    └─ parses <<transition_id::16, welcome::binary>>
         │    └─ calls davey.process_welcome(welcome)
         │    └─ sends op 23 (transition_ready)
         │  On op 22 (execute_transition):
         │    └─ sets dave_ready = true, streaming can begin
         ▼
    TTS.Engine
         │  synthesize(text) → PCM s16le 48kHz mono
         ▼
    Opus.encode/1
         │  ffmpeg PCM → Opus via libopus
         ▼
    Streaming
         │  send_frame/1 — RTP header + encrypted Opus + nonce (4 bytes)
         │  every 20ms via :tick
         │  sends Speaking (op 5) on start/stop
```

## Files

| File | Role |
|------|------|
| `tts.ex` | Manager GenServer: per-guild queue, creates/monitors Sessions |
| `session.ex` | Per-session GenServer: voice WS, UDP discovery, encoding, streaming |
| `voice_connection.ex` | Callback module for websocket_client (voice WS) |
| `engine.ex` | Behaviour for TTS providers |
| `engine/edge.ex` | Edge TTS provider (`edge-tts` Python CLI) |
| `audio.ex` | MP3/Opus → PCM conversion via FFmpeg |
| `opus.ex` | PCM → Opus encoding (ffmpeg + libopus) |
| `ogg.ex` | Ogg container parser, extracts Opus packets |

## Voice Gateway — websocket_client 1.6.1

### Supported callbacks

| Callback | Valid returns | Note |
|----------|--------------|------|
| `onconnect/2` | `{:ok, state}` | `{:reply, frame, state}` is **NOT** supported — crashes with `CaseClauseError` |
| `websocket_handle/3` | `{:ok, state}`, `{:reply, frame, state}`, `{:close, payload, state}` | 3-element tuple (`{atom, frame, state}`), NOT `{:ok, :reply, ws_req, frame, state}` |
| `websocket_info/3` | `{:ok, state}`, `{:reply, frame, state}`, `{:close, payload, state}` | |
| `ondisconnect/2` | `{:ok, state}`, `{:reconnect, state}`, `{:close, reason, state}` | Returning `{:close, nil, state}` causes `**(stop) nil` |

### Frame types

- `:text` / `:binary` — both work
- All JSON payloads are sent as `{:text, json_string}`
- `:cast` via `:websocket_client.cast(self(), {:text, payload})` works in `websocket_info` but NOT in `websocket_handle`

### Voice WS — v8 / DAVE (E2EE)

- **Identify must include** `max_dave_protocol_version: 1` (mandatory since March 2026)
- DAVE (E2EE) is required — without it the server rejects (closes SSL)
- Heartbeat uses `{"op":3,"d":{"t":<ms>,"seq_ack":<seq>}}`
- Incoming DAVE binary frames use v8 format: `<<seq::16, opcode::8, payload>>`
- Outgoing DAVE binary frames use v4 format: `<<opcode::8, payload>>` (no seq prefix — Discord disconnects on v8)

### DAVE binary frame parsing (critical)

Discord sends DAVE frames in v8 wire format:

```
<<seq::16-big, opcode::8, payload::binary>>
```

The payload for each opcode varies. Important ones:

| Opcode | Name | Payload format |
|--------|------|---------------|
| 25 | external_sender | `<<sender::binary>>` |
| 27 | proposals | `<<transition_id::16, proposals::binary>>` |
| 29 | announce_commit | `<<transition_id::16, commit::binary>>` |
| 30 | welcome | `<<transition_id::16, welcome::binary>>` |
| 22 | execute_transition | `<<transition_id::16>>` |

**Important:** `transition_id` is always **16-bit** (2 bytes, uint16 big-endian). A common mistake is parsing it as `::32` (4 bytes), which corrupts the subsequent commit/welcome data by:
- Including the first 2 bytes of the real commit into the transition_id
- Passing a commit that starts 2 bytes too late to `davey.process_commit()`

This causes the MLS handshake to fail silently — `davey` creates a session but it never reaches `ready` state. The `encrypt_opus` call returns `"NotReady"` and all audio frames fail.

**Correct Elixir pattern match (session.ex):**
```elixir
<<transition_id::16, commit::binary>> = payload   # right
# NOT:
<<transition_id::32, commit::binary>> = payload   # wrong — corrupts commit
```

## DAVE handshake flow (davey Python library)

The project uses `davey` (PyPI package 0.1.5, Rust native wheel) via a Python port process (`priv/dave_handler.py`). The Python process communicates with the Elixir GenServer (`Dave` module) via stdin/stdout JSON messages.

| Step | What happens |
|------|-------------|
| 1. Session Description (op 4) | `davey.get_serialized_key_package()` → sends op 26 |
| 2. op 25 (external_sender) | `davey.set_external_sender()` |
| 3. op 27 (proposals) | `davey.process_proposals()` → may return commit → op 23 |
| 4. op 29 (announce_commit) | `davey.process_commit()` → op 23 |
| 5. op 30 (welcome) | `davey.process_welcome()` → op 23 |
| 6. op 22 (execute_transition) | Elixir sets `dave_ready = true` |
| 7. Streaming | Each frame: `davey.encrypt_opus(opus_data)` → encrypted + nonce → UDP |

The transition_id in ops 27/29/30 must be echoed back in the `transition_ready` (op 23) response.

## Encryption modes (post-Nov 2024)

Obsolete modes removed. Current:

| Mode | Cipher | Nonce |
|------|--------|-------|
| `aead_aes256_gcm_rtpsize` | `:aes_256_gcm` | 4 bytes (sequence), zero-padded to 12 |
| `aead_xchacha20_poly1305_rtpsize` | `:chacha20_poly1305` (provisional) | 4 bytes |

4-byte nonce appended at end of UDP packet (`header|ciphertext|tag|nonce`).

## IP Discovery (UDP)

Packet format (big-endian):

| Offset | Field | Size |
|--------|-------|------|
| 0 | Type (0x0001) | 2 bytes |
| 2 | Length (70 = 0x0046) | 2 bytes |
| 4 | SSRC | 4 bytes |

Response (big-endian):

| Offset | Field | Size |
|--------|-------|------|
| 0 | Type (0x0002) | 2 bytes |
| 2 | Length (70) | 2 bytes |
| 4 | SSRC | 4 bytes |
| 8 | IP (null-terminated) | 64 bytes |
| 72 | Port | 2 bytes |

## Timeouts

| Timeout | Duration | Where |
|---------|----------|-------|
| Session timeout | 60s | Session `@timeout_ms` — cancels if DAVE/streaming doesn't progress |
| TTS encode | 30s | `Task.yield/2` in `encode_tts` |
| UDP discovery | 2s | `:gen_udp.recv/3` |
| Tick (frame) | 20ms | `Process.send_after` |
| cleanup delay | 300ms | `Process.send_after` on finish |

## External dependencies

- Python + `pip install edge-tts davey` (Edge TTS + DAVE E2EE)
- FFmpeg with libopus (`ffmpeg -codecs | grep opus`)
- Erlang/OTP 27+ (`:crypto` with aes_256_gcm)

## Environment

```bash
export TTS_PROVIDER=edge
export TTS_VOICE=pt-BR-FranciscaNeural
```
