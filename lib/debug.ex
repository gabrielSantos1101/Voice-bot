defmodule ArcaneVoice.Debug do
  @moduledoc false

  use GenServer

  @debug_dir System.tmp_dir!() <> "/arcane_voice_debug"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def set(key, value) do
    GenServer.call(__MODULE__, {:set, key, value})
  end

  def all do
    GenServer.call(__MODULE__, :all)
  end

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:set, key, value}, _from, state) do
    {:reply, :ok, Map.put(state, key, value)}
  end

  def handle_call(:all, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    File.mkdir_p!(@debug_dir)
    now = System.system_time(:second)
    for file <- File.ls!(@debug_dir) do
      path = Path.join(@debug_dir, file)
      if File.regular?(path) do
        mtime = File.stat!(path, time: :posix).mtime
        if now - mtime > 3600 do
          File.rm(path)
        end
      end
    end
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 3600_000)
  end
end