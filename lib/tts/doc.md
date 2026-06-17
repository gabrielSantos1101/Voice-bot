# ArcaneStack TTS — Discord Text-to-Speech

## Flow

```
Usuário envia /tts <texto>
         │
         ▼
    TTS.handle_interaction/1
         │  ── acha canal de voz do usuário
         │  ── enfileira (se já tem sessão ativa) ou cria Session
         ▼
    TTS.Session
         │  init/1
         │    ── pede bot_user_id via :discord_bot
         │    ── recebe bot_user_id → envia voice_state_update (op 4) p/ entrar no canal
         │    ── recebe voice_state (session_id) + voice_server (token, endpoint)
         ▼
    TTS.VoiceConnection   (websocket_client 1.6.1)
         │  connecta wss://<endpoint>/?v=4
         │  recebe Hello (op 8, heartbeat_interval)
         │  envia Identify (op 0) com max_dave_protocol_version: 1
         │  recebe Ready (op 2) → ssrc, ip, port, modes
         ▼
    TTS.Session
         │  discover_ip/1 — UDP discovery (Type+Length+SSRC big-endian)
         │  envia Select Protocol (op 1) via VoiceConnection
         │  recebe Session Description (op 4) → secret_key
         ▼
    TTS.Engine
         │  synthesize(texto) → PCM s16le 48kHz mono
         ▼
    Opus.encode/1
         │  ffmpeg PCM → Opus via libopus
         ▼
    Streaming
         │  send_frame/1 — RTP header + ciphertext + tag + nonce (4 bytes)
         │  a cada 20ms via :tick
         │  envia Speaking (op 5) ao iniciar/parar
```

## Arquivos

| Arquivo | Função |
|---------|--------|
| `tts.ex` | GenServer gerenciador: fila por guild, cria/monitora Sessions |
| `session.ex` | GenServer por sessão: voz WS, UDP discovery, encoding, streaming |
| `voice_connection.ex` | Callback module pro websocket_client (voz WS) |
| `engine.ex` | Comportamento abstrato p/ providers TTS |
| `engine/edge.ex` | Provider Edge TTS (`edge-tts` CLI Python) |
| `audio.ex` | Converte MP3/Opus → PCM via FFmpeg |
| `opus.ex` | Codifica PCM → Opus (ffmpeg + libopus) |
| `ogg.ex` | Parse Ogg container, extrai packets Opus |

## Voice Gateway — websocket_client 1.6.1

### Callbacks suportados

| Callback | Retornos válidos | Nono |
|----------|-----------------|------|
| `onconnect/2` | `{:ok, state}` | `{:reply, frame, state}` **NÃO** é suportado — crasha com `CaseClauseError` |
| `websocket_handle/3` | `{:ok, state}`, `{:reply, frame, state}`, `{:close, payload, state}` | Formato de 3 elementos (`{atom, frame, state}`), NÃO `{:ok, :reply, ws_req, frame, state}` |
| `websocket_info/3` | `{:ok, state}`, `{:reply, frame, state}`, `{:close, payload, state}` | |
| `ondisconnect/2` | `{:ok, state}`, `{:reconnect, state}`, `{:close, reason, state}` | Retornar `{:close, nil, state}` causa `**(stop) nil` |

### Frame types

- `:text` / `:binary` — ambos funcionam
- Todes os payloads JSON são enviados como `{:text, json_string}`
- `:cast` via `:websocket_client.cast(self(), {:text, payload})` funciona em `websocket_info` mas NÃO em `websocket_handle`

### Voice WS — v4 (funcional)

- **Identify deve incluir** `max_dave_protocol_version: 1` (obrigatório desde Março/2026)
- DAVE (E2EE) é mandatório — sem o campo o servidor rejeita (fecha SSL)
- Nonce do heartbeat: inteiro direto (`{"op":3,"d":<nonce>}`) na v4

## Encryption modes (pós-Nov/2024)

Modos obsoletos removidos. Hoje apenas:

| Modo | Cipher | Nonce |
|------|--------|-------|
| `aead_aes256_gcm_rtpsize` | `:aes_256_gcm` | 4 bytes (sequence), zero-padded p/ 12 |
| `aead_xchacha20_poly1305_rtpsize` | `:chacha20_poly1305` (provisório) | 4 bytes |

Nonce de 4 bytes é anexado ao final do pacote UDP (`header|ciphertext|tag|nonce`).

## IP Discovery (UDP)

Formato do pacote (big-endian):

| Offset | Campo | Tamanho |
|--------|-------|---------|
| 0 | Type (0x0001) | 2 bytes |
| 2 | Length (70 = 0x0046) | 2 bytes |
| 4 | SSRC | 4 bytes |

Resposta (big-endian):

| Offset | Campo | Tamanho |
|--------|-------|---------|
| 0 | Type (0x0002) | 2 bytes |
| 2 | Length (70) | 2 bytes |
| 4 | SSRC | 4 bytes |
| 8 | IP (null-terminated) | 64 bytes |
| 72 | Port | 2 bytes |

## Timeouts

| Timeout | Duração | Onde |
|---------|---------|------|
| Session timeout | 15s | Session `@timeout_ms` — cancela se voz WS nāo conectar |
| TTS encode | 10s | `Task.yield/2` no `encode_tts` |
| UDP discovery | 2s | `:gen_udp.recv/3` |
| Tick (frame) | 20ms | `Process.send_after` |
| cleanup delay | 300ms | `Process.send_after` no finish |

## Dependências externas

- Python + `pip install edge-tts` (provider Edge)
- FFmpeg com libopus (`ffmpeg -codecs | grep opus`)
- Erlang/OTP 27+ (`:crypto` com aes_256_gcm)

## Ambiente

```bash
export TTS_PROVIDER=edge
export TTS_VOICE=pt-BR-FranciscaNeural
```
