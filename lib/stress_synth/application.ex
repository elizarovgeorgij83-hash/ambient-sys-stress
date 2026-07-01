defmodule StressSynth.Application do
  @moduledoc """
  Main OTP application module for StressSynth.

  Bootstraps the supervision tree, launching:
    * a Registry for naming dynamic worker processes
    * the system monitor supervisor (CPU/memory/disk/network probes)
    * a dynamic supervisor for spawning stress-test workload generators
    * the Phoenix (or plain Cowboy) web endpoint providing the dashboard/API

  The tree uses the `:one_for_one` strategy at the top level so that a
  crash in one subsystem (e.g. the web endpoint) does not bring down
  unrelated subsystems (e.g. running monitors).
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Read runtime configuration, falling back to sensible defaults so the
    # app can boot even without an explicit config file (e.g. in tests).
    port = Application.get_env(:stress_synth, :port, 4000)
    monitor_interval_ms = Application.get_env(:stress_synth, :monitor_interval_ms, 1_000)

    children = [
      # PubSub is used to broadcast live metrics from monitors to the web
      # layer (LiveView channels, websockets, etc.) without tight coupling.
      {Phoenix.PubSub, name: StressSynth.PubSub},

      # Registry used to look up named worker/monitor processes by id,
      # e.g. {:via, Registry, {StressSynth.Registry, :cpu_monitor}}.
      {Registry, keys: :unique, name: StressSynth.Registry},

      # Supervises the individual system monitors (CPU, memory, disk, net).
      # Each monitor periodically samples system metrics and publishes them
      # via PubSub for consumption by the web dashboard.
      {StressSynth.Monitors.Supervisor, interval_ms: monitor_interval_ms},

      # Dynamic supervisor responsible for spawning and tearing down
      # stress-test workload generators (CPU burners, memory hogs, I/O
      # thrashers, etc.) on demand, requested via the web API.
      {DynamicSupervisor, name: StressSynth.Workloads.Supervisor, strategy: :one_for_one},

      # The web endpoint exposing the dashboard UI and JSON/WebSocket API
      # for controlling and observing stress tests.
      {StressSynth.Web.Endpoint, port: port}
    ]

    Logger.info("Starting StressSynth application on port #{port}")

    opts = [strategy: :one_for_one, name: StressSynth.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    # Allows the web endpoint to pick up configuration changes without a
    # full application restart (used by Phoenix's code reloader in dev).
    StressSynth.Web.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping StressSynth application")
    :ok
  end
end
