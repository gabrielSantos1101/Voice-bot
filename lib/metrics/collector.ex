defmodule ArcaneVoice.Metrics.Collector do
  use Prometheus.Metric

  @registry :arcane_voice_registry

  def start do
    Gauge.new(
      name: :arcane_voice_connected_sessions,
      registry: @registry,
      labels: [],
      help: "Currently connected sessions count."
    )

    Counter.new(
      name: :arcane_voice_messages_outbound,
      registry: @registry,
      labels: [],
      help: "Total socket messages outbout."
    )

    Counter.new(
      name: :arcane_voice_messages_inbound,
      registry: @registry,
      labels: [],
      help: "Total messages received count."
    )

    Counter.new(
      name: :arcane_voice_2xx_responses,
      registry: @registry,
      labels: [],
      help: "2xx http responses"
    )

    Counter.new(
      name: :arcane_voice_4xx_responses,
      registry: @registry,
      labels: [],
      help: "4xx http responses"
    )

    Counter.new(
      name: :arcane_voice_5xx_responses,
      registry: @registry,
      labels: [],
      help: "5xx http responses"
    )

    Counter.new(
      name: :arcane_voice_discord_messages_sent,
      registry: @registry,
      labels: [],
      help: "Messages sent to discord count"
    )
  end

  def dec(:gauge, stat) do
    Gauge.dec(name: stat, registry: @registry)
  end

  def inc(:gauge, stat) do
    Gauge.inc(name: stat, registry: @registry)
  end

  def inc(:counter, stat) do
    Counter.inc(name: stat, registry: @registry)
  end

  def inc(:gauge, stat, value) do
    Gauge.inc([name: stat, registry: @registry], value)
  end

  def set(:gauge, stat, value) do
    Gauge.set([name: stat, registry: @registry], value)
  end
end
