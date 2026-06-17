defmodule ArcaneVoice.TTS do
  use GenServer

  require Logger

  defstruct sessions: %{}, queues: %{}

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

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:voice_state, data}, state) do
    guild_id = data["guild_id"]
    Enum.each(state.sessions, fn {sguild_id, pid} ->
      if sguild_id == guild_id do
        send(pid, {:voice_state, data})
      end
    end)
    {:noreply, state}
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
  def handle_call({:speak, info}, _from, state) do
    pid = start_session(info.guild_id, info)
    Process.monitor(pid)
    send(pid, {:tts_config, self(), info.guild_id})
    {:reply, :ok, %{state | sessions: Map.put(state.sessions, info.guild_id, pid)}}
  end

  defp dequeue_next(state, guild_id) do
    case Map.get(state.queues, guild_id, []) do
      [next | rest] ->
        st = if rest == [], do: %{state | queues: Map.delete(state.queues, guild_id)},
                else: put_in(state, [:queues, guild_id], rest)

        pid = start_session(guild_id, %{next | voice_channel_id: next.voice_channel_id})
        send(pid, {:tts_config, self(), guild_id})
        Logger.info("TTS: dequeued item for guild #{guild_id}")
        put_in(st, [:sessions, guild_id], pid)

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
