defmodule ArcaneVoice.TTS do
  use GenServer

  require Logger

  @default_idle_timeout_ms 300_000
  @default_voice "pt-BR-FranciscaNeural"
  @max_text_length 300

  @voices [
    %{
      label: "Brasil - Francisca",
      value: "pt-BR-FranciscaNeural",
      description: "Português do Brasil, voz feminina"
    },
    %{
      label: "Brasil - Antonio",
      value: "pt-BR-AntonioNeural",
      description: "Português do Brasil, voz masculina"
    },
    %{
      label: "Portugal - Raquel",
      value: "pt-PT-RaquelNeural",
      description: "Português de Portugal, voz feminina"
    },
    %{
      label: "Portugal - Duarte",
      value: "pt-PT-DuarteNeural",
      description: "Português de Portugal, voz masculina"
    },
    %{
      label: "English - Jenny",
      value: "en-US-JennyNeural",
      description: "English US, feminine voice"
    },
    %{
      label: "English - Guy",
      value: "en-US-GuyNeural",
      description: "English US, masculine voice"
    }
  ]

  @idle_options [
    {"1 minuto", 60_000},
    {"5 minutos", 300_000},
    {"10 minutos", 600_000},
    {"30 minutos", 1_800_000}
  ]

  defstruct sessions: %{}, queues: %{}, voice_states: %{}, settings: %{}, idle_sessions: MapSet.new(), user_voices: %{}, joined_users: %{}, last_speaker: %{}, processed_interactions: %{}, processed_messages: %{}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def voice_state_update(data) do
    GenServer.cast(__MODULE__, {:voice_state, data})
  end

  def voice_server_update(data) do
    GenServer.cast(__MODULE__, {:voice_server, data})
  end

  def speak(%{guild_id: guild_id} = info) do
    GenServer.call(__MODULE__, {:speak, info}, 5000)
  end

  def get_user_voice_channel(guild_id, user_id) do
    GenServer.call(__MODULE__, {:get_user_voice_channel, guild_id, user_id})
  end

  def bulk_voice_states(guild_id, voice_states) do
    GenServer.cast(__MODULE__, {:bulk_voice_states, guild_id, voice_states})
  end

  def handle_interaction(data) do
    GenServer.cast(__MODULE__, {:handle_interaction, data})
  end

  def handle_message(data) do
    GenServer.cast(__MODULE__, {:handle_message, data})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:voice_state, data}, state) do
    guild_id = data["guild_id"]
    user_id = data["user_id"]

    state = cond do
      data["channel_id"] == nil ->
        guild_states = Map.get(state.voice_states, guild_id, %{})
        vs = Map.put(state.voice_states, guild_id, Map.delete(guild_states, user_id))
        %{state | voice_states: vs}

      true ->
        vs = put_in(state.voice_states, [guild_id, user_id], data)
        %{state | voice_states: vs}
    end

    Enum.each(state.sessions, fn {sguild_id, pid} ->
      if sguild_id == guild_id do
        send(pid, {:voice_state, data})
      end
    end)
    {:noreply, state}
  end

  def handle_cast({:bulk_voice_states, guild_id, voice_states}, state) do
    indexed = Map.new(voice_states, fn vs -> {vs["user_id"], vs} end)
    {:noreply, %{state | voice_states: Map.put(state.voice_states, guild_id, indexed)}}
  end

  def handle_cast({:voice_server, data}, state) do
    guild_id = data["guild_id"]
    Logger.debug("TTS: voice_server_update for guild=#{guild_id}, sessions=#{inspect(Map.keys(state.sessions))}")
    Enum.each(state.sessions, fn {sguild_id, pid} ->
      if sguild_id == guild_id do
        Logger.debug("TTS: forwarding voice_server to session #{inspect(pid)}")
        send(pid, {:voice_server, data})
      end
    end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_interaction, data}, state) do
    interaction_id = data["id"]

    state =
      if Map.has_key?(state.processed_interactions, interaction_id) do
        Logger.debug("TTS: ignoring duplicate interaction #{interaction_id}")
        state
      else
        processed = cleanup_cache(state.processed_interactions)
        state = %{state | processed_interactions: Map.put(processed, interaction_id, :os.system_time(:second))}

        case data do
          %{"type" => 2, "data" => %{"name" => "tts"} = cmd_data} ->
            handle_tts_slash(data, cmd_data, state)

          %{"type" => 2, "data" => %{"name" => "settings"}} ->
            handle_settings_slash(data, state)

          %{"type" => 2, "data" => %{"name" => "voice"}} ->
            handle_voice_slash(data, state)

          %{"type" => 2, "data" => %{"name" => "join"}} ->
            handle_join_slash(data, state)

          %{"type" => 2, "data" => %{"name" => "leave"}} ->
            handle_leave_slash(data, state)

          %{"type" => 3, "data" => %{"custom_id" => custom_id}} ->
            handle_component(data, custom_id, state)

          _ ->
            Logger.debug("TTS: unknown interaction type=#{data["type"]}")
            state
        end
      end

    {:noreply, state}
  end

  def handle_cast({:handle_message, data}, state) do
    if get_in(data, ["author", "bot"]) == true do
      {:noreply, state}
    else
      message_id = data["id"]

      if Map.has_key?(state.processed_messages, message_id) do
        Logger.debug("TTS: ignoring duplicate message #{message_id}")
        {:noreply, state}
      else
        processed = cleanup_cache(state.processed_messages)
        state = %{state | processed_messages: Map.put(processed, message_id, :os.system_time(:second))}

        guild_id = data["guild_id"]
        user_id = data["author"]["id"]
        text = data["content"]

        text = String.replace(text, ~r/<a?:\w+:\d+>/, "") |> String.replace(~r/:[\w]+:/, "") |> String.replace(~r/https?:\/\/[^\s]+/, "") |> String.trim()

        guild_joined = Map.get(state.joined_users, guild_id, %{})

        case Map.get(guild_joined, user_id) do
          nil ->
            {:noreply, state}

          joined_info ->
            if text in ["", nil] do
              {:noreply, state}
            else
              channel_id = get_in(state.voice_states, [guild_id, user_id, "channel_id"]) || joined_info.channel_id

              if is_nil(channel_id) do
                guild_joined = Map.delete(guild_joined, user_id)
                {:noreply, %{state | joined_users: Map.put(state.joined_users, guild_id, guild_joined)}}
              else
                last = Map.get(state.last_speaker, guild_id)
                {prefix, state} = if last == user_id do
                  {nil, state}
                else
                  {"#{joined_info.display_name} disse: ", %{state | last_speaker: Map.put(state.last_speaker, guild_id, user_id)}}
                end

                text = String.slice("#{prefix}#{text}", 0, @max_text_length)

                settings = settings_for(state, guild_id)
                user_voice = get_in(state.user_voices, [guild_id, user_id])
                settings = if user_voice, do: %{settings | voice: user_voice}, else: settings

                info = %{
                  voice_channel_id: channel_id,
                  text: text,
                  interaction_token: "",
                  voice: settings.voice,
                  idle_timeout_ms: 1_800_000
                }

                {:noreply, queue_or_start_session(state, guild_id, info)}
              end
            end
        end
      end
    end
  end

  @impl true
  def handle_info({:session_ended, guild_id, pid}, state) do
    if Map.get(state.sessions, guild_id) == pid do
      state = %{
        state |
        sessions: Map.delete(state.sessions, guild_id),
        idle_sessions: MapSet.delete(state.idle_sessions, guild_id),
        joined_users: Map.delete(state.joined_users, guild_id),
        last_speaker: Map.delete(state.last_speaker, guild_id)
      }
      {:noreply, dequeue_next(state, guild_id)}
    else
      Logger.debug("TTS: ignoring stale session_ended for guild=#{guild_id} pid=#{inspect(pid)}")
      {:noreply, state}
    end
  end

  def handle_info({:session_ended, guild_id}, state) do
    Logger.warning("TTS: session_ended without pid for guild #{guild_id}, cleaning up")
    state = %{
      state |
      sessions: Map.delete(state.sessions, guild_id),
      idle_sessions: MapSet.delete(state.idle_sessions, guild_id),
      joined_users: Map.delete(state.joined_users, guild_id),
      last_speaker: Map.delete(state.last_speaker, guild_id)
    }
    {:noreply, dequeue_next(state, guild_id)}
  end

  def handle_info({:stream_started, guild_id, pid}, state) do
    case Map.get(state.queues, guild_id, []) do
      [next | _] ->
        send(pid, {:prefetch, next.text})
      [] ->
        :ok
    end
    {:noreply, state}
  end

  def handle_info({:session_idle, guild_id, pid}, state) do
    if Map.get(state.sessions, guild_id) == pid do
      case Map.get(state.queues, guild_id, []) do
        [next | rest] ->
          st =
            if rest == [] do
              %{state | queues: Map.delete(state.queues, guild_id)}
            else
              %{state | queues: Map.put(state.queues, guild_id, rest)}
            end

          send(pid, {:play_next, next})
          {:noreply, %{st | idle_sessions: MapSet.delete(st.idle_sessions, guild_id)}}

        [] ->
          {:noreply, %{state | idle_sessions: MapSet.put(state.idle_sessions, guild_id)}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    guild_id = Enum.find_value(state.sessions, fn {g, p} -> if p == pid, do: g end)
    if guild_id, do: send(self(), {:session_ended, guild_id, pid})
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("TTS: unhandled #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_user_voice_channel, guild_id, user_id}, _from, state) do
    channel_id = get_in(state.voice_states, [guild_id, user_id, "channel_id"])
    {:reply, channel_id, state}
  end

  @impl true
  def handle_call({:speak, info}, _from, state) do
    settings = settings_for(state, info.guild_id)
    info = apply_settings(info, settings)
    pid = start_session(info.guild_id, info)
    Process.monitor(pid)
    send(pid, {:tts_config, self(), info.guild_id})
    {:reply, :ok, %{state | sessions: Map.put(state.sessions, info.guild_id, pid)}}
  end

  defp handle_tts_slash(data, cmd_data, state) do
    guild_id = data["guild_id"]
    user_id = get_in(data, ["member", "user", "id"]) || data["user"]["id"]
    text = get_text_option(cmd_data)
    text = if text, do: text |> String.replace(~r/<a?:\w+:\d+>/, "") |> String.replace(~r/:[\w]+:/, "") |> String.replace(~r/https?:\/\/[^\s]+/, "") |> String.trim() |> String.slice(0, @max_text_length), else: nil
    interaction_token = data["token"]
    settings = settings_for(state, guild_id)
    user_voice = get_in(state.user_voices, [guild_id, user_id])
    settings = if user_voice, do: %{settings | voice: user_voice}, else: settings

    cond do
      is_nil(text) ->
        respond_interaction(data, %{
          "type" => 4,
          "data" => %{"content" => "Você precisa fornecer um texto para falar.", "flags" => 64}
        })
        state

      true ->
        channel_id = get_in(state.voice_states, [guild_id, user_id, "channel_id"])

        {channel_id, state} = if is_nil(channel_id) do
          case ArcaneVoice.DiscordBot.DiscordApi.get_user_voice_state(guild_id, user_id) do
            {:ok, voice_state} ->
              if ch_id = voice_state["channel_id"] do
                vs = put_in(state.voice_states, [guild_id, user_id], voice_state)
                {ch_id, %{state | voice_states: vs}}
              else
                {nil, state}
              end
            _ ->
              {nil, state}
          end
        else
          {channel_id, state}
        end

        if is_nil(channel_id) do
          respond_interaction(data, %{
            "type" => 4,
            "data" => %{"content" => "Você precisa estar em um canal de voz para usar este comando.", "flags" => 64}
          })
          state

        else
          text = if settings.read_username do
            display_name = get_in(data, ["member", "nick"]) || get_in(data, ["member", "user", "global_name"]) || get_in(data, ["member", "user", "username"]) || "Alguém"
            "#{display_name} disse: #{text}"
          else
            text
          end
          text = String.slice(text, 0, @max_text_length)
          respond_interaction(data, %{
            "type" => 4,
            "data" => %{"content" => text}
          })

          info = apply_settings(%{voice_channel_id: channel_id, text: text, interaction_token: interaction_token}, settings)

          if Map.has_key?(state.sessions, guild_id) do
            if MapSet.member?(state.idle_sessions, guild_id) do
              send(state.sessions[guild_id], {:play_next, info})
              %{state | idle_sessions: MapSet.delete(state.idle_sessions, guild_id)}
            else
              queue = Map.get(state.queues, guild_id, [])
              %{state | queues: Map.put(state.queues, guild_id, queue ++ [info])}
            end
          else
            pid = start_session(guild_id, info)
            Process.monitor(pid)
            send(pid, {:tts_config, self(), guild_id})
            %{state | sessions: Map.put(state.sessions, guild_id, pid)}
          end
        end
    end
  end

  defp get_text_option(%{"options" => options}) do
    Enum.find_value(options || [], fn
      %{"name" => "text", "value" => value} -> value
      _ -> nil
    end)
  end

  defp get_text_option(_), do: nil

  defp handle_join_slash(data, state) do
    guild_id = data["guild_id"]
    user_id = get_in(data, ["member", "user", "id"]) || data["user"]["id"]
    channel_id = get_in(state.voice_states, [guild_id, user_id, "channel_id"])

    {channel_id, state} = if is_nil(channel_id) do
      case ArcaneVoice.DiscordBot.DiscordApi.get_user_voice_state(guild_id, user_id) do
        {:ok, voice_state} ->
          if ch_id = voice_state["channel_id"] do
            vs = put_in(state.voice_states, [guild_id, user_id], voice_state)
            {ch_id, %{state | voice_states: vs}}
          else
            {nil, state}
          end
        _ -> {nil, state}
      end
    else
      {channel_id, state}
    end

    if is_nil(channel_id) do
      respond_interaction(data, %{
        "type" => 4,
        "data" => %{"content" => "Você precisa estar em um canal de voz para usar este comando.", "flags" => 64}
      })
      state
    else
      guild_joined = Map.get(state.joined_users, guild_id, %{})

      if Map.has_key?(guild_joined, user_id) do
        respond_interaction(data, %{
          "type" => 4,
          "data" => %{"content" => "Você já está inscrito para leitura de mensagens.", "flags" => 64}
        })
        state
      else
        display_name = get_in(data, ["member", "nick"]) || get_in(data, ["member", "user", "global_name"]) || get_in(data, ["member", "user", "username"]) || "Alguém"

        guild_joined = Map.put(guild_joined, user_id, %{channel_id: channel_id, display_name: display_name})
        state = %{state | joined_users: Map.put(state.joined_users, guild_id, guild_joined)}

        respond_interaction(data, %{
          "type" => 4,
          "data" => %{"content" => "Suas mensagens de texto agora serão lidas em voz alta.", "flags" => 64}
        })

        info = %{
          voice_channel_id: channel_id,
          text: nil,
          interaction_token: "",
          voice: Application.get_env(:arcane_voice, :tts_voice, @default_voice),
          idle_timeout_ms: 1_800_000
        }

        queue_or_start_session(state, guild_id, info)
      end
    end
  end

  defp handle_leave_slash(data, state) do
    guild_id = data["guild_id"]
    user_id = get_in(data, ["member", "user", "id"]) || data["user"]["id"]
    guild_joined = Map.get(state.joined_users, guild_id, %{})

    if Map.has_key?(guild_joined, user_id) do
      guild_joined = Map.delete(guild_joined, user_id)
      state = %{state | joined_users: Map.put(state.joined_users, guild_id, guild_joined)}

      if guild_joined == %{} do
        state = %{state | last_speaker: Map.delete(state.last_speaker, guild_id)}
      end

      respond_interaction(data, %{
        "type" => 4,
        "data" => %{"content" => "Suas mensagens não serão mais lidas em voz alta.", "flags" => 64}
      })

      state
    else
      respond_interaction(data, %{
        "type" => 4,
        "data" => %{"content" => "Você não está inscrito para leitura de mensagens.", "flags" => 64}
      })

      state
    end
  end

defp handle_settings_slash(data, state) do
    guild_id = data["guild_id"]
    settings = settings_for(state, guild_id)

    respond_interaction(data, %{
      "type" => 4,
      "data" => %{
        "flags" => 64,
        "content" => settings_content(settings),
        "components" => settings_components(settings)
      }
    })

    state
  end

  defp handle_component(data, "settings:voice", state) do
    guild_id = data["guild_id"]
    voice = data |> get_in(["data", "values"]) |> List.first()

    if valid_voice?(voice) do
      settings = settings_for(state, guild_id) |> Map.put(:voice, voice)
      state = put_settings(state, guild_id, settings)

      respond_interaction(data, %{
        "type" => 4,
        "data" => %{"flags" => 64, "content" => "Voz atualizada para #{voice_label(voice)}."}
      })

      state
    else
      respond_interaction(data, %{
        "type" => 4,
        "data" => %{"flags" => 64, "content" => "Essa voz não está disponível."}
      })

      state
    end
  end

  defp handle_component(data, "settings:idle_timeout", state) do
    guild_id = data["guild_id"]
    value = data |> get_in(["data", "values"]) |> List.first()

    case Integer.parse(value || "") do
      {idle_timeout_ms, ""} ->
        settings = settings_for(state, guild_id) |> Map.put(:idle_timeout_ms, idle_timeout_ms)
        state = put_settings(state, guild_id, settings)

        respond_interaction(data, %{
          "type" => 4,
          "data" => %{"flags" => 64, "content" => "Tempo em call atualizado para #{idle_label(idle_timeout_ms)}."}
        })

        state

      _ ->
        respond_interaction(data, %{
          "type" => 4,
          "data" => %{"flags" => 64, "content" => "Tempo inválido."}
        })

        state
    end
  end

  defp handle_component(data, "settings:read_username", state) do
    guild_id = data["guild_id"]
    value = data |> get_in(["data", "values"]) |> List.first()

    read = value == "true"
    settings = settings_for(state, guild_id) |> Map.put(:read_username, read)
    state = put_settings(state, guild_id, settings)

    respond_interaction(data, %{
      "type" => 4,
      "data" => %{"flags" => 64, "content" => "Leitura de nome #{if read, do: "ativada", else: "desativada"}."}
    })

    state
  end

  defp handle_voice_slash(data, state) do
    guild_id = data["guild_id"]
    user_id = get_in(data, ["member", "user", "id"]) || data["user"]["id"]
    user_voice = get_in(state.user_voices, [guild_id, user_id])

    respond_interaction(data, %{
      "type" => 4,
      "data" => %{
        "flags" => 64,
        "content" => "Escolha sua voz padrão:",
        "components" => [
          %{
            "type" => 1,
            "components" => [
              %{
                "type" => 3,
                "custom_id" => "voice:set",
                "placeholder" => "Minha voz",
                "min_values" => 1,
                "max_values" => 1,
                "options" =>
                  [%{"label" => "Padrão do servidor", "value" => "", "description" => "Usar a voz configurada no servidor", "default" => is_nil(user_voice)}] ++
                  Enum.map(@voices, fn voice ->
                    %{
                      "label" => voice.label,
                      "value" => voice.value,
                      "description" => voice.description,
                      "default" => voice.value == user_voice
                    }
                  end)
              }
            ]
          }
        ]
      }
    })

    state
  end

  defp handle_component(data, "voice:set", state) do
    guild_id = data["guild_id"]
    user_id = get_in(data, ["member", "user", "id"]) || data["user"]["id"]
    voice = data |> get_in(["data", "values"]) |> List.first()

    if voice == "" do
      guild_voices = Map.get(state.user_voices, guild_id, %{})
      guild_voices = Map.drop(guild_voices, [user_id])
      state = if guild_voices == %{} do
        %{state | user_voices: Map.delete(state.user_voices, guild_id)}
      else
        %{state | user_voices: Map.put(state.user_voices, guild_id, guild_voices)}
      end

      respond_interaction(data, %{
        "type" => 4,
        "data" => %{"flags" => 64, "content" => "Voz pessoal removida. Usando a voz padrão do servidor."}
      })

      state
    else
      guild_voices = Map.get(state.user_voices, guild_id, %{})
      guild_voices = Map.put(guild_voices, user_id, voice)
      state = %{state | user_voices: Map.put(state.user_voices, guild_id, guild_voices)}

      respond_interaction(data, %{
        "type" => 4,
        "data" => %{"flags" => 64, "content" => "Sua voz foi definida para #{voice_label(voice)}."}
      })

      state
    end
  end

  defp handle_component(data, custom_id, state) do
    Logger.debug("TTS: unknown component #{custom_id}")
    respond_interaction(data, %{
      "type" => 4,
      "data" => %{"flags" => 64, "content" => "Componente desconhecido."}
    })

    state
  end

  defp respond_interaction(data, body) do
    interaction_id = data["id"]
    token = data["token"]
    url = "https://discord.com/api/v10/interactions/#{interaction_id}/#{token}/callback"
    encoded = Jason.encode!(body)

    Task.start(fn ->
      respond_interaction_retry(url, encoded, 3)
    end)
  end

  defp respond_interaction_retry(_url, _encoded, 0) do
    Logger.error("TTS: interaction response exhausted retries")
  end

  defp respond_interaction_retry(url, encoded, retries) do
    try do
      case :post
           |> Finch.build(url, [{"Content-Type", "application/json"}], encoded)
           |> Finch.request(ArcaneVoice.Finch) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.debug("TTS: interaction responded (status #{status})")

        {:ok, %{status: status, body: resp_body}} when status in [429] ->
          Logger.warning("TTS: rate limited (#{status}), retrying (#{retries - 1} left)")
          Process.sleep(1000)
          respond_interaction_retry(url, encoded, retries - 1)

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("TTS: interaction rejected (status #{status}): #{resp_body}")

        {:error, reason} ->
          Logger.error("TTS: interaction request failed: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.error("TTS: respond_interaction crashed: #{inspect(e)}")
    end
  end

  defp dequeue_next(state, guild_id) do
    case Map.get(state.queues, guild_id, []) do
      [next | rest] ->
        st = if rest == [], do: %{state | queues: Map.delete(state.queues, guild_id)},
                else: %{state | queues: Map.put(state.queues, guild_id, rest)}

        pid = start_session(guild_id, %{next | voice_channel_id: next.voice_channel_id})
        Process.monitor(pid)
        send(pid, {:tts_config, self(), guild_id})
        Logger.info("TTS: dequeued item for guild #{guild_id}")
        %{st | sessions: Map.put(st.sessions, guild_id, pid)}

      [] ->
        state
    end
  end

  defp start_session(guild_id, info) do
    {:ok, pid} = ArcaneVoice.TTS.Session.start_link(
      guild_id: guild_id,
      channel_id: info.voice_channel_id,
      text: info.text,
      interaction_token: Map.get(info, :interaction_token, ""),
      voice: Map.get(info, :voice, @default_voice),
      idle_timeout_ms: Map.get(info, :idle_timeout_ms, @default_idle_timeout_ms)
    )
    pid
  end

  defp settings_for(state, guild_id) do
    Map.get(state.settings, guild_id, %{
      voice: Application.get_env(:arcane_voice, :tts_voice, @default_voice),
      idle_timeout_ms: @default_idle_timeout_ms,
      read_username: false
    })
  end

  defp put_settings(state, guild_id, settings) do
    %{state | settings: Map.put(state.settings, guild_id, settings)}
  end

  defp apply_settings(info, settings) do
    info
    |> Map.put(:voice, settings.voice)
    |> Map.put(:idle_timeout_ms, settings.idle_timeout_ms)
  end

  defp settings_content(settings) do
    "Configurações atuais\nVoz do servidor: #{voice_label(settings.voice)}\nTempo em call: #{idle_label(settings.idle_timeout_ms)}\nLer nome: #{if settings.read_username, do: "Sim", else: "Não"}"
  end

  defp settings_components(settings) do
    [
      %{
        "type" => 1,
        "components" => [
          %{
            "type" => 3,
            "custom_id" => "settings:voice",
            "placeholder" => "Voz do servidor",
            "min_values" => 1,
            "max_values" => 1,
            "options" =>
              Enum.map(@voices, fn voice ->
                %{
                  "label" => voice.label,
                  "value" => voice.value,
                  "description" => voice.description,
                  "default" => voice.value == settings.voice
                }
              end)
          }
        ]
      },
      %{
        "type" => 1,
        "components" => [
          %{
            "type" => 3,
            "custom_id" => "settings:idle_timeout",
            "placeholder" => "Tempo antes de sair da call",
            "min_values" => 1,
            "max_values" => 1,
            "options" =>
              Enum.map(@idle_options, fn {label, value} ->
                %{
                  "label" => label,
                  "value" => Integer.to_string(value),
                  "description" => "Sair da call depois de #{label} sem áudio",
                  "default" => value == settings.idle_timeout_ms
                }
              end)
          }
        ]
      },
      %{
        "type" => 1,
        "components" => [
          %{
            "type" => 3,
            "custom_id" => "settings:read_username",
            "placeholder" => "Ler nome do usuário",
            "min_values" => 1,
            "max_values" => 1,
            "options" => [
              %{"label" => "Desativado", "value" => "false", "description" => "Não ler o nome (padrão)", "default" => !settings.read_username},
              %{"label" => "Ativado", "value" => "true", "description" => "Ler o nome antes da mensagem", "default" => settings.read_username}
            ]
          }
        ]
      }
    ]
  end

  defp cleanup_cache(cache) do
    now = :os.system_time(:second)
    cache |> Enum.filter(fn {_id, ts} -> now - ts < 60 end) |> Map.new()
  end

  defp valid_voice?(voice), do: Enum.any?(@voices, &(&1.value == voice))

  defp voice_label(voice) do
    case Enum.find(@voices, &(&1.value == voice)) do
      nil -> voice
      found -> found.label
    end
  end

  defp idle_label(ms) do
    case Enum.find(@idle_options, fn {_label, value} -> value == ms end) do
      nil -> "#{div(ms, 60_000)} minutos"
      {label, _value} -> label
    end
  end

  defp queue_or_start_session(state, guild_id, info) do
    if Map.has_key?(state.sessions, guild_id) do
      if MapSet.member?(state.idle_sessions, guild_id) do
        send(state.sessions[guild_id], {:play_next, info})
        %{state | idle_sessions: MapSet.delete(state.idle_sessions, guild_id)}
      else
        queue = Map.get(state.queues, guild_id, [])
        %{state | queues: Map.put(state.queues, guild_id, queue ++ [info])}
      end
    else
      pid = start_session(guild_id, info)
      Process.monitor(pid)
      send(pid, {:tts_config, self(), guild_id})
      %{state | sessions: Map.put(state.sessions, guild_id, pid)}
    end
  end
end
