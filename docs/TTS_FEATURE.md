# TTS (Text-to-Speech) — Arquitetura

## Visão Geral

O TTS permite que o bot reproduza texto em voz natural em canais de voz do
Discord, similar ao `/tts` nativo do Discord porém com qualidade muito superior
(Edge Neural Voices da Microsoft).

### Fluxo de Uso

```text
Usuário: /tts Olá pessoal, bem-vindos!
  → Bot responde com "Pensando..."
  → Bot entra no canal de voz do usuário
  → Bot gera o áudio via Edge-TTS + FFmpeg
  → Bot transmite o áudio no canal de voz
  → Bot sai do canal de voz
```

## Arquitetura de Módulos

```
lib/tts/
  ├── tts.ex                # GenServer top-level
  ├── session.ex            # Sessão de uma reprodução
  ├── voice_connection.ex   # WebSocket de voz do Discord
  ├── engine.ex             # Abstração de provedores TTS
  ├── engine/edge.ex        # Edge-TTS (Microsoft Neural)
  ├── audio.ex              # Conversão MP3 → PCM via FFmpeg
  ├── opus.ex               # PCM → frames Opus (FFmpeg + Ogg)
  └── ogg.ex                # Parser Ogg Opus
```

### Responsabilidades

| Módulo | Função |
|--------|--------|
| `TTS` | Gerencia sessões por guild, roteia eventos do Gateway, recebe slash command |
| `TTS.Session` | Orquestra uma reprodução: join → conectar voz → stream → sair |
| `TTS.VoiceConnection` | Client WebSocket de voz (protocolo v4), envia heartbeat e speaking |
| `TTS.Engine` | Struct + behaviour para provedores TTS |
| `TTS.Engine.Edge` | Síntese via `edge-tts` + FFmpeg, retorna PCM s16le 48kHz |
| `TTS.Audio` | Utilitário de conversão FFmpeg (qualquer formato → PCM) |
| `TTS.Opus` | Codifica PCM para frames Opus individuais (20ms cada) |
| `TTS.Ogg` | Extrai pacotes Opus de arquivos Ogg Opus |

### Decisões de Arquitetura

**1. Edge-TTS como provedor padrão**

- Gratuito, vozes neurais da Microsoft (mesmas do Edge Read Aloud)
- Voz PT-BR nativa: `pt-BR-FranciscaNeural` (feminina) e `pt-BR-AntonioNeural` (masculina)
- Qualidade superior ao TTS padrão do Discord (robótico)
- Alternativas viáveis: OpenAI TTS (pago), ElevenLabs (pago)

**2. Protocolo de Voz do Discord (v8 com DAVE E2EE)**

- Implementação manual do Voice Gateway WebSocket v8 + UDP
- DAVE (Discord Audio & Video End-to-End Encryption) é obrigatório desde Março 2026
- Criptografia via `davey` (biblioteca Python/Rust, MLS) + `:crypto.crypto_one_time_aead` (OTP nativo)
- Modo `aead_aes256_gcm_rtpsize` (preferido) ou `aead_xchacha20_poly1305_rtpsize` (fallback)
- Handshake DAVE: `key_package` enviado no Session Description (op 4), antes do `external_sender` (op 25)
- Frames DAVE incoming: v8 (`<<seq::16, opcode::8, payload>>`)
- Frames DAVE outgoing: v4 (`<<opcode::8, payload>>`)
- `transition_id` em ops 27/29/30 é **16-bit** — erro comum é parsear como 32-bit, corrompendo o commit/welcome e impedindo o MLS de se estabelecer (`session.ready = false`)
- Dependência externa: `davey` (PyPI), compilado como wheel nativo Rust

**3. Pipeline de Áudio**

```text
Edge-TTS → MP3 → FFmpeg (decode) → PCM s16le 48kHz mono
  → FFmpeg + libopus (encode) → Ogg Opus
    → Parser Ogg → frames Opus individuais (20ms)
      → davey.encrypt_opus() → RTP header + ciphertext + nonce → UDP
```

**4. Por que FFmpeg + Ogg parser em vez de libopus NIF?**

- FFmpeg já é necessário para conversão de áudio
- Ogg parsing é simples (~50 linhas) e não requer NIFs
- Evita dependências de bibliotecas C compiladas
- Tolerante a variações de formato

### Protocolo de Voz

#### WebSocket (Voz)

```text
1. Conectar: wss://{endpoint}/?v=4
2. Servidor: Hello (op 8) → heartbeat_interval
3. Client:    Identify (op 0) → server_id, user_id, session_id, token
4. Servidor: Ready (op 2) → ssrc, ip, port, modes[]
5. Client:    UDP IP discovery (pacote de 70 bytes)
6. Client:    Select Protocol (op 1) → address, port, mode
7. Servidor: Session Description (op 4) → mode, secret_key[32]
8. Client:    Send Speaking (op 5) → speaking=true
9. Client:    Audio UDP → RTP header + encrypted Opus + tag
10. Client:   Send Speaking (op 5) → speaking=false
11. Client:   Close WebSocket
```

#### Pacote de Áudio UDP (chacha20_poly1305)

```text
[12 bytes RTP header]  ← nonce e AAD
  Versão: 2 (0x80)
  Payload: 120 (0x78)
  Sequence: uint16 big-endian (incrementa por frame)
  Timestamp: uint32 big-endian (incrementa 960 por frame)
  SSRC: uint32 big-endian
[s66 bytes encrypted Opus frame]  ← ChaCha20-Poly1305
[16 bytes auth tag]
```

### Configuração

```env
# Provider: edge (default, gratuito) | openai | elevenlabs
TTS_PROVIDER=edge

# Voz do Edge-TTS para PT-BR
TTS_VOICE=pt-BR-FranciscaNeural

# Alternativas:
# pt-BR-AntonioNeural (masculino)
# pt-BR-BrendaNeural (feminino)
# en-US-JennyNeural (inglês)
```

### Dependências de Sistema

| Programa | Obrigatório? | Função |
|----------|-------------|--------|
| Python 3.8+ | Sim (com edge-tts) | Síntese de voz |
| `pip install edge-tts` | Sim | CLI do Edge TTS |
| FFmpeg | Sim | Decodificação/codificação de áudio |

### Instalação do Edge-TTS

```bash
pip install edge-tts
```

### Comando Slash

- **Nome:** `/tts`
- **Opção:** `texto` (string, obrigatório)
- **Descrição:** "Reproduzir texto em voz no canal de voz"
- O bot identifica automaticamente o canal de voz do usuário via REST API

### Limitações Conhecidas

- Texto muito longo (>200 caracteres) pode demorar para sintetizar
- Edge-TTS tem latência de ~300-500ms na primeira chamada (cold start Python)
- Apenas uma reprodução por vez por guild (sessões por guild_id)
- O bot precisa da permissão `Connect` e `Speak` no canal de voz

### Para Replicar em Outro Projeto

O coração do sistema são três partes independentes:

1. **TTS Engine** — chama edge-tts (ou API), retorna áudio
2. **Voice Gateway** — WebSocket + UDP do protocolo de voz do Discord
3. **Streamer** — codifica PCM para Opus, encripta e envia via UDP

Para implementar em outra linguagem (Python, JS, Go), mantenha o mesmo pipeline:

```text
Síntese → PCM 48kHz → Opus 20ms frames → encrypt → UDP
```

A parte mais complexa é o Voice Gateway WebSocket (handshake + heartbeat).
O UDP audio segue um formato fixo e previsível.
