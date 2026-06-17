defmodule ArcaneVoice.MixProject do
  use Mix.Project

  def project do
    [
      app: :arcane_voice,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :corsica],
      mod: {ArcaneVoice, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.19"},
      {:bandit, "~> 1.8"},
      {:prometheus_plugs, "~> 1.1"},
      {:prometheus_ex,
       git: "https://github.com/lanodan/prometheus.ex", branch: "fix/elixir-1.14", override: true},
      {:websocket_client, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:corsica, "~> 2.1"},
      {:finch, "~> 0.20.0"},
      {:redix, "~> 1.5"}
    ]
  end
end
