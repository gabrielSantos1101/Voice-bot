defmodule ArcaneVoice.TTS.Dave do
  @moduledoc """
  Manages a long-running Python `davey` process for DAVE MLS handshakes.

  Communication uses a JSON-line protocol over stdin/stdout.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init_session(guild_id, user_id, channel_id) do
    GenServer.call(__MODULE__, {:init, guild_id, user_id, channel_id}, 30_000)
  end

  def get_serialized_key_package(guild_id) do
    GenServer.call(__MODULE__, {:get_serialized_key_package, guild_id}, 30_000)
  end

  def set_external_sender(guild_id, payload) do
    GenServer.call(__MODULE__, {:set_external_sender, guild_id, payload}, 30_000)
  end

  def process_proposals(guild_id, optype, payload) do
    GenServer.call(__MODULE__, {:process_proposals, guild_id, optype, payload}, 30_000)
  end

  def process_commit(guild_id, payload) do
    GenServer.call(__MODULE__, {:process_commit, guild_id, payload}, 30_000)
  end

  def process_welcome(guild_id, payload) do
    GenServer.call(__MODULE__, {:process_welcome, guild_id, payload}, 30_000)
  end

  def handshake_done?(guild_id) do
    GenServer.call(__MODULE__, {:handshake_done, guild_id}, 10_000)
  end

  def close(guild_id) do
    GenServer.cast(__MODULE__, {:close, guild_id})
  end

  def encrypt_opus(guild_id, frame) do
    GenServer.call(__MODULE__, {:encrypt_opus, guild_id, frame}, 10_000)
  end

  @impl true
  def init(_opts) do
    script = application_priv_dir() |> then(&Path.join(&1, "dave_handler.py"))
    port = Port.open(
      {:spawn, "python3 -u #{script}"},
      [:binary, :exit_status]
    )
    Logger.info("Dave: Python process started (#{script})")
    {:ok, %{port: port, pending: [], buf: ""}}
  end

  @impl true
  def handle_call({:init, guild_id, user_id, channel_id}, from, state) do
    {:noreply, queue_cmd(%{cmd: "init", guild_id: guild_id, user_id: user_id, channel_id: channel_id}, from, state)}
  end

  def handle_call({:get_serialized_key_package, guild_id}, from, state) do
    {:noreply, queue_cmd(%{cmd: "get_serialized_key_package", guild_id: guild_id}, from, state)}
  end

  def handle_call({:set_external_sender, guild_id, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "set_external_sender", guild_id: guild_id, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:process_proposals, guild_id, optype, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "process_proposals", guild_id: guild_id, optype: optype, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:process_commit, guild_id, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "process_commit", guild_id: guild_id, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:process_welcome, guild_id, payload}, from, state) do
    {:noreply, queue_cmd(%{cmd: "process_welcome", guild_id: guild_id, payload: Base.encode64(payload)}, from, state)}
  end

  def handle_call({:handshake_done, guild_id}, from, state) do
    {:noreply, queue_cmd(%{cmd: "handshake_done", guild_id: guild_id}, from, state)}
  end

  def handle_call({:encrypt_opus, guild_id, frame}, from, state) do
    {:noreply, queue_cmd(%{cmd: "encrypt_opus", guild_id: guild_id, frame: Base.encode64(frame)}, from, state)}
  end

  @impl true
  def handle_cast({:close, guild_id}, state) do
    {:noreply, queue_cmd(%{cmd: "close", guild_id: guild_id}, nil, state)}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
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
        Logger.info("Dave: Python ready, davey=#{resp["have_davey"]}")
        if from, do: GenServer.reply(from, {:ok, resp["have_davey"]})
        %{state | pending: rest}

      "ok" ->
        if from, do: GenServer.reply(from, :ok)
        %{state | pending: rest}

      "ready" ->
        gid = resp["guild_id"]
        Logger.info("Dave: guild #{gid} handshake ready")
        if from, do: GenServer.reply(from, {:ok, :ready})
        %{state | pending: rest}

      "not_ready" ->
        if from, do: GenServer.reply(from, {:ok, false})
        %{state | pending: rest}

      "response" ->
        payload = Base.decode64!(resp["payload"])
        Logger.info("Dave: response opcode=#{resp["opcode"]} size=#{resp["size"] || byte_size(payload)}b")
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
