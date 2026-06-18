defmodule ArcaneVoice.TTS.Dave do
  @moduledoc """
  Manages a long-running Python `sorrydave` process for DAVE MLS handshakes.

  Communication uses a JSON-line protocol over stdin/stdout.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init_session(guild_id, user_id) do
    GenServer.call(__MODULE__, {:init, guild_id, user_id}, 30_000)
  end

  def prepare_epoch(guild_id) do
    GenServer.call(__MODULE__, {:prepare_epoch, guild_id}, 30_000)
  end

  def handle_external_sender(guild_id, payload) do
    GenServer.call(__MODULE__, {:handle_external_sender, guild_id, payload}, 30_000)
  end

  def handle_proposals(guild_id, payload) do
    GenServer.call(__MODULE__, {:handle_proposals, guild_id, payload}, 30_000)
  end

  def handle_commit(guild_id, transition_id, payload) do
    GenServer.call(__MODULE__, {:handle_commit, guild_id, transition_id, payload}, 30_000)
  end

  def handle_welcome(guild_id, transition_id, payload) do
    GenServer.call(__MODULE__, {:handle_welcome, guild_id, transition_id, payload}, 30_000)
  end

  def execute_transition(guild_id, transition_id) do
    GenServer.call(__MODULE__, {:execute_transition, guild_id, transition_id}, 30_000)
  end

  def handshake_done?(guild_id) do
    GenServer.call(__MODULE__, {:handshake_done, guild_id}, 10_000)
  end

  def close(guild_id) do
    GenServer.cast(__MODULE__, {:close, guild_id})
  end

  def encrypt_frame(guild_id, frame, codec \\ "OPUS") do
    GenServer.call(__MODULE__, {:encrypt_frame, guild_id, frame, codec}, 10_000)
  end

  @impl true
  def init(_opts) do
    script = application_priv_dir() |> then(&Path.join(&1, "dave_handler.py"))
    port = Port.open(
      {:spawn, "python3 -u #{script}"},
      [:binary, :exit_status]
    )
    Logger.info("Dave: Python process started (#{script})")
    {:ok, %{port: port, pending: [], sessions: %{}, buf: ""}}
  end

  @impl true
  def handle_call({:init, guild_id, user_id}, from, state) do
    {:noreply, queue_cmd(%{cmd: "init", guild_id: guild_id, user_id: user_id}, from, state)}
  end

  def handle_call({:prepare_epoch, guild_id}, from, state) do
    {:noreply, queue_cmd(%{cmd: "prepare_epoch", guild_id: guild_id, epoch: 1}, from, state)}
  end

  def handle_call({:handle_external_sender, guild_id, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "handle_external_sender", guild_id: guild_id, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:handle_proposals, guild_id, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "handle_proposals", guild_id: guild_id, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:handle_commit, guild_id, transition_id, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "handle_commit", guild_id: guild_id, transition_id: transition_id, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:handle_welcome, guild_id, transition_id, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "handle_welcome", guild_id: guild_id, transition_id: transition_id, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:execute_transition, guild_id, transition_id}, from, state) do
    {:noreply, queue_cmd(%{cmd: "execute_transition", guild_id: guild_id, transition_id: transition_id}, from, state)}
  end

  def handle_call({:handshake_done, guild_id}, from, state) do
    {:noreply, queue_cmd(%{cmd: "handshake_done", guild_id: guild_id}, from, state)}
  end

  def handle_call({:encrypt_frame, guild_id, frame, codec}, from, state) do
    {:noreply, queue_cmd(%{cmd: "get_encryptor", guild_id: guild_id, frame: Base.encode64(frame), codec: codec}, from, state)}
  end

  @impl true
  def handle_cast({:close, guild_id}, state) do
    {:noreply, queue_cmd(%{cmd: "close", guild_id: guild_id}, nil, state)}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # flush remaining buffer
    state = drain_buf(%{state | port: nil})
    Logger.error("Dave: Python process exited with status #{status}")
    {:stop, {:dave_crashed, status}, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buf} = split_lines(state.buf <> data)
    state = Enum.reduce(lines, state, &process_line(&1, &2))
    {:noreply, %{state | buf: buf}}
  end

  defp split_lines(data) do
    case String.split(data, "\n") do
      [single] ->
        {[], single}
      parts ->
        all_but_last = Enum.take(parts, length(parts) - 1)
        last = List.last(parts)
        {all_but_last, last}
    end
  end

  defp drain_buf(state) do
    if state.buf != "" do
      _ = process_line(state.buf, %{state | pending: []})
      %{state | buf: ""}
    else
      state
    end
  end

  defp queue_cmd(cmd, from, state) do
    json = Jason.encode!(cmd)
    Port.command(state.port, json <> "\n")
    %{state | pending: state.pending ++ [from]}
  end

  defp process_line(line, state) do
    line = String.trim(line)
    if line == "" do
      state
    else
      case Jason.decode(line) do
        {:ok, resp} -> handle_response(resp, state)
        {:error, _} ->
          Logger.warning("Dave: invalid JSON: #{line}")
          state
      end
    end
  end

  defp handle_response(resp, state) do
    {from, rest} = case state.pending do
      [f | r] -> {f, r}
      [] -> {nil, []}
    end

    case resp["type"] do
      "hello" ->
        Logger.info("Dave: Python ready, sorrydave=#{resp["have_sorrydave"]}")
        if from, do: GenServer.reply(from, {:ok, resp["have_sorrydave"]})
        %{state | pending: rest}

      "ok" ->
        if from, do: GenServer.reply(from, :ok)
        %{state | pending: rest}

      "ready" ->
        gid = resp["guild_id"]
        Logger.info("Dave: guild #{gid} handshake ready")
        if from, do: GenServer.reply(from, {:ok, :ready})
        %{state | pending: rest, sessions: Map.put(state.sessions, gid, :ready)}

      "not_ready" ->
        if from, do: GenServer.reply(from, {:ok, false})
        %{state | pending: rest}

      "response" ->
        payload = Base.decode64!(resp["payload"])
        if from, do: GenServer.reply(from, {:ok, %{opcode: resp["opcode"], payload: payload}})
        %{state | pending: rest}

      "error" ->
        Logger.error("Dave: #{inspect(resp["message"])}")
        if from, do: GenServer.reply(from, {:error, resp["message"]})
        %{state | pending: rest}

      _ ->
        Logger.warning("Dave: unknown type=#{resp["type"]}")
        if from, do: GenServer.reply(from, {:error, "unknown response: #{resp["type"]}"})
        %{state | pending: rest}
    end
  end

  defp application_priv_dir do
    case :code.priv_dir(:arcane_voice) do
      {:error, _} -> Path.join(File.cwd!(), "priv")
      path -> path
    end
  end
end
