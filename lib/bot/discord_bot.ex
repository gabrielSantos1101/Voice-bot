defmodule ArcaneVoice.DiscordBot do
  use GenServer

  require Logger

  alias ArcaneVoice.Gateway

  defstruct token: nil,
            gateway_client_pid: nil,
            resume_data: nil,
            user_id: nil

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: :discord_bot)
  end

  def init(state) do
    {:ok, %__MODULE__{token: state.token, gateway_client_pid: nil}, {:continue, :setup_bot}}
  end

  def handle_continue(:setup_bot, state) do
    gateway_state = %{token: state.token}

    gateway_state =
      case state.resume_data do
        nil -> gateway_state
        resume_data -> Map.merge(gateway_state, resume_data)
      end

    {_, pid} = Gateway.Client.start_link(gateway_state)
    Process.monitor(pid)

    Logger.info("Discord bot running on #{inspect(pid)}")

    {:noreply, %{state | gateway_client_pid: pid, resume_data: nil}}
  end

  def handle_info({:prepare_resume, resume_data}, state) do
    {:noreply, %{state | resume_data: resume_data}}
  end

  def handle_info(:clear_resume, state) do
    {:noreply, %{state | resume_data: nil}}
  end

  def handle_info({:get_bot_user_id, from}, state) do
    send(from, {:bot_user_id, state.user_id})
    {:noreply, state}
  end

  def handle_info({:bot_ready, user_id}, state) do
    Logger.info("Voice bot ready with user_id: #{user_id}")

    Task.start(fn ->
      ArcaneVoice.DiscordBot.DiscordApi.register_commands(user_id)
    end)

    {:noreply, %{state | user_id: user_id}}
  end

  def handle_info({:voice_state_update, guild_id, channel_id, self_mute, self_deaf}, state) do
    send(state.gateway_client_pid, {:send_voice_state, guild_id, channel_id, self_mute, self_deaf})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("Discord bot crashed with reason: #{reason}. Restarting.")

    {:noreply, state, {:continue, :setup_bot}}
  end
end
