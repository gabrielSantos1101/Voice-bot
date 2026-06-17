defmodule ArcaneVoice.TTS do
  use GenServer

  require Logger

  defstruct sessions: %{}, queues: %{}, voice_states: %{}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def voice_state_update(data) do
    GenServer.cast(__MODULE__, {:voice_state, data})
  end

  def voice_server_update(data) do
    GenServer.cast(__MODULE__, {:voice_server, data})
  end

  def speak(%{text: text, voice_channel_id: voice_channel_id, guild_id: guild_id} = info) do
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
    new_state =
      case data do
        %{"type" => 2, "data" => %{"name" => "tts"} = cmd_data} ->
          handle_tts_slash(data, cmd_data, state)

        _ ->
          Logger.debug("TTS: unknown interaction type=#{data["type"]}")
          state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:session_ended, guild_id}, state) do
    state = %{state | sessions: Map.delete(state.sessions, guild_id)}
    {:noreply, dequeue_next(state, guild_id)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    guild_id = Enum.find_value(state.sessions, fn {g, p} -> if p == pid, do: g end)
    if guild_id, do: send(self(), {:session_ended, guild_id})
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("TTS: unhandled #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_user_voice_channel, guild_id, user_id}, _from, state) do
    channel_id = get_in(state, [:voice_states, guild_id, user_id, "channel_id"])
    {:reply, channel_id, state}
  end

  @impl true
  def handle_call({:speak, info}, _from, state) do
    pid = start_session(info.guild_id, info)
    Process.monitor(pid)
    send(pid, {:tts_config, self(), info.guild_id})
    {:reply, :ok, %{state | sessions: Map.put(state.sessions, info.guild_id, pid)}}
  end

  defp handle_tts_slash(data, cmd_data, state) do
    guild_id = data["guild_id"]
    user_id = get_in(data, ["member", "user", "id"]) || data["user"]["id"]
    text = get_text_option(cmd_data)

    cond do
      is_nil(text) ->
        respond_interaction(data, %{
          "type" => 4,
          "data" => %{"content" => "You need to provide text to speak.", "flags" => 64}
        })

      true ->
        channel_id = get_in(state, [:voice_states, guild_id, user_id, "channel_id"])

        if is_nil(channel_id) do
          respond_interaction(data, %{
            "type" => 4,
            "data" => %{"content" => "You need to be in a voice channel to use this command.", "flags" => 64}
          })
        else
          respond_interaction(data, %{
            "type" => 4,
            "data" => %{"content" => "Speaking...", "flags" => 64}
          })

          pid = start_session(guild_id, %{voice_channel_id: channel_id, text: text})
          Process.monitor(pid)
          send(pid, {:tts_config, self(), guild_id})
          %{state | sessions: Map.put(state.sessions, guild_id, pid)}
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

  defp respond_interaction(data, body) do
    interaction_id = data["id"]
    token = data["token"]
    url = "https://discord.com/api/v10/interactions/#{interaction_id}/#{token}/callback"

    Task.start(fn ->
      case :post
           |> Finch.build(url, [{"Content-Type", "application/json"}], Jason.encode!(body))
           |> Finch.request(ArcaneVoice.Finch) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("TTS: interaction response failed: #{inspect(reason)}")
      end
    end)
  end

  defp dequeue_next(state, guild_id) do
    case Map.get(state.queues, guild_id, []) do
      [next | rest] ->
        st = if rest == [], do: %{state | queues: Map.delete(state.queues, guild_id)},
                else: %{state | queues: Map.put(state.queues, guild_id, rest)}

        pid = start_session(guild_id, %{next | voice_channel_id: next.voice_channel_id})
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
      interaction_token: ""
    )
    pid
  end
end
