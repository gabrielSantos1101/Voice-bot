# ArcaneVoice

Bot de voz exclusivo do servidor [**Arcane**](https://discord.gg/v9Nb6GQd).

Standalone Discord voice bot para Text-to-Speech usando edge-tts (Microsoft Edge TTS engine).

Converte mensagens de texto em áudio falado em canais de voz do Discord. Executa independentemente como um bot separado no servidor.

## How it works

1. HTTP request to `POST /tts` with `{ "guild_id": "...", "channel_id": "...", "text": "..." }`
2. Bot joins the specified voice channel via Discord Gateway
3. Establishes a UDP voice connection with IP discovery (74-byte Discord.js‑compatible packet format)
4. Streams PCM audio (48kHz stereo, 16-bit) through Discord Voice WebSocket
5. Encrypts audio with `aead_aes256_gcm_rtpsize` (4-byte nonce, zero-padded to 12)
6. Leaves the channel when done

## Requirements

- Erlang/OTP 27+
- Elixir 1.18+
- Python 3.x with `edge-tts` (`pip install edge-tts`)
- Discord Bot Token with `voice_states` and `guilds` intents

## Quick start

```bash
# 1. Copy and fill in your env vars
cp .env.example .env
# Edit .env with your BOT_TOKEN

# 2. Install dependencies
mix deps.get

# 3. Run
mix run --no-halt
```

## Configuration

Copy `.env.example` to `.env` and set the required variables:

| Variable | Description |
|---|---|
| `BOT_TOKEN` | Discord bot token |
| `PORT` | HTTP server port (default: 4001) |
| `BOT_PRESENCE` | Bot status text (default: "voice") |
| `BOT_PRESENCE_TYPE` | Status type 0-5 (default: 3 = listening) |

Redis is optional and only needed for future features. Leave `REDIS_HOST` unset to skip.

## API

### `GET /health`

Health check endpoint. Returns `200 OK` with `"ok"`. Useful for keeping the bot alive on free-tier hosting.

### `POST /tts`

Request the bot to speak text in a voice channel.

**Body:**
```json
{
  "guild_id": "123456789",
  "channel_id": "987654321",
  "text": "Hello, this is ArcaneVoice speaking"
}
```

## Technical details

- **Protocol**: Discord Voice v4 (with DAVE protocol, `max_dave_protocol_version: 1`)
- **Encryption**: AEAD_AES256_GCM_RTPSIZE
- **Sample rate**: 48 kHz
- **Channels**: Stereo
- **Sample format**: Signed 16-bit little-endian PCM
- **IP discovery**: 74-byte packet (`<<0x00, 0x01, 0x00, 0x46, ssrc::32, 0::size(528)>>`)
- **TTS Engine**: Microsoft Edge TTS (via `edge-tts` Python CLI)

## Project structure

```
lib/
├── api/
│   ├── router.ex          # HTTP routes (health, tts)
│   └── routes/
│       └── tts.ex         # POST /tts handler
├── connectivity/
│   └── redis.ex           # Redis utilities (optional, not in supervision)
├── gateway/
│   ├── client.ex          # Discord Gateway WebSocket client
│   ├── heartbeat.ex       # Heartbeat handling
│   └── utility.ex         # Gateway helpers
├── tts/
│   ├── session.ex         # Voice session lifecycle (join, speak, leave)
│   ├── connection.ex      # UDP/voice WebSocket connection
│   ├── opus.ex            # Opus encoding
│   └── engine/
│       └── edge.ex        # edge-tts Python wrapper
├── metrics.ex
├── discord_bot.ex         # Discord bot supervisor
└── arcane_voice.ex        # Application root + supervision tree
```
