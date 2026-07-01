defmodule StressSynth.MetricsCollector do
  @moduledoc """
  GenServer that polls system diagnostics at high frequency to capture
  thermal fluctuations, memory spikes, and scheduler/run-queue pressure.

  Designed for stress-testing scenarios where short-lived spikes matter:
  the collector keeps a bounded ring buffer of the most recent samples
  in memory and can emit alerts via `:telemetry` when configurable
  thresholds are crossed.

  ## Usage

      {:ok, pid} = StressSynth.MetricsCollector.start_link(
        poll_interval_ms: 50,
        buffer_size: 2000,
        memory_spike_threshold_mb: 256,
        temp_spike_threshold_c: 85
      )

      StressSynth.MetricsCollector.latest(pid)
      StressSynth.MetricsCollector.history(pid, 100)
      StressSynth.MetricsCollector.stats(pid)
  """

  use GenServer
  require Logger

  @default_poll_interval_ms 100
  @default_buffer_size 1_000
  @default_memory_spike_threshold_mb 512
  @default_temp_spike_threshold_c 90.0

  # ----------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------

  @typedoc "A single diagnostics sample captured at a point in time."
  @type sample :: %{
          timestamp: integer(),
          memory_total_bytes: non_neg_integer(),
          memory_processes_bytes: non_neg_integer(),
          memory_atom_bytes: non_neg_integer(),
          memory_binary_bytes: non_neg_integer(),
          memory_ets_bytes: non_neg_integer(),
          process_count: non_neg_integer(),
          run_queue: non_neg_integer(),
          scheduler_utilization: [float()],
          temperature_c: float() | nil,
          gc_count: non_neg_integer(),
          gc_words_reclaimed: non_neg_integer()
        }

  @doc """
  Starts the metrics collector.

  ## Options

    * `:poll_interval_ms` - how often to poll diagnostics (default: #{@default_poll_interval_ms})
    * `:buffer_size` - max number of samples kept in the ring buffer (default: #{@default_buffer_size})
    * `:memory_spike_threshold_mb` - delta in MB between consecutive samples that
      triggers a `:memory_spike` telemetry event (default: #{@default_memory_spike_threshold_mb})
    * `:temp_spike_threshold_c` - absolute temperature in Celsius that triggers
      a `:thermal_spike` telemetry event (default: #{@default_temp_spike_threshold_c})
    * `:name` - GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the most recent sample, or `nil` if none captured yet."
  @spec latest(GenServer.server()) :: sample() | nil
  def latest(server \\ __MODULE__) do
    GenServer.call(server, :latest)
  end

  @doc "Returns up to `count` most recent samples, newest first."
  @spec history(GenServer.server(), pos_integer()) :: [sample()]
  def history(server \\ __MODULE__, count \\ 100) do
    GenServer.call(server, {:history, count})
  end

  @doc "Returns aggregate statistics (min/max/avg) computed over the buffer."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @doc "Forces an immediate poll, bypassing the timer. Useful for tests."
  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server \\ __MODULE__) do
    GenServer.call(server, :poll_now)
  end

  @doc "Clears the internal buffer."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  # ----------------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct [
      :poll_interval_ms,
      :buffer_size,
      :memory_spike_threshold_bytes,
      :temp_spike_threshold_c,
      :timer_ref,
      # buffer stored newest-first for O(1) prepend
      buffer: [],
      buffer_len: 0,
      last_sample: nil,
      # cache the GC counters between polls to compute deltas
      last_gc_totals: {0, 0, 0}
    ]
  end

  @impl true
  def init(opts) do
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)

    memory_spike_mb =
      Keyword.get(opts, :memory_spike_threshold_mb, @default_memory_spike_threshold_mb)

    temp_spike_c =
      Keyword.get(opts, :temp_spike_threshold_c, @default_temp_spike_threshold_c)

    state = %State{
      poll_interval_ms: poll_interval_ms,
      buffer_size: buffer_size,
      memory_spike_threshold_bytes: memory_spike_mb * 1024 * 1024,
      temp_spike_threshold_c: temp_spike_c
    }

    # Schedule the first poll immediately so callers get data fast.
    timer_ref = schedule_poll(0)

    {:ok, %State{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_poll(state)
    timer_ref = schedule_poll(new_state.poll_interval_ms)
    {:noreply, %State{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:latest, _from, state) do
    {:reply, state.last_sample, state}
  end

  def handle_call({:history, count}, _from, state) do
    {:reply, Enum.take(state.buffer, count), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, compute_stats(state.buffer), state}
  end

  def handle_call(:poll_now, _from, state) do
    new_state = do_poll(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %State{state | buffer: [], buffer_len: 0, last_sample: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  # ----------------------------------------------------------------------
  # Internal helpers
  # ----------------------------------------------------------------------

  defp schedule_poll(delay_ms) do
    Process.send_after(self(), :poll, delay_ms)
  end

  # Performs a single diagnostics poll: gathers memory, scheduler, process
  # and (best-effort) thermal data, then updates the ring buffer and emits
  # telemetry events if thresholds are crossed.
  defp do_poll(state) do
    sample = capture_sample(state)

    maybe_emit_spikes(state, sample)

    new_buffer = [sample | state.buffer]

    {trimmed_buffer, new_len} =
      if state.buffer_len + 1 > state.buffer_size do
        {Enum.take(new_buffer, state.buffer_size), state.buffer_size}
      else
        {new_buffer, state.buffer_len + 1}
      end

    %State{
      state
      | buffer: trimmed_buffer,
        buffer_len: new_len,
        last_sample: sample
    }
  end

  defp capture_sample(_state) do
    memory = :erlang.memory()
    {run_queue, _} = {:erlang.statistics(:run_queue), nil}
    scheduler_util = scheduler_utilization()
    {gc_count, gc_words, _} = :erlang.statistics(:garbage_collection)

    %{
      timestamp: System.monotonic_time(:millisecond),
      memory_total_bytes: Keyword.get(memory, :total, 0),
      memory_processes_bytes: Keyword.get(memory, :processes, 0),
      memory_atom_bytes: Keyword.get(memory, :atom, 0),
      memory_binary_bytes: Keyword.get(memory, :binary, 0),
      memory_ets_bytes: Keyword.get(memory, :ets, 0),
      process_count: :erlang.system_info(:process_count),
      run_queue: run_queue,
      scheduler_utilization: scheduler_util,
      temperature_c: read_temperature(),
      gc_count: gc_count,
      gc_words_reclaimed: gc_words
    }
  end

  # Attempts to obtain scheduler utilization percentages via the BEAM's
  # scheduler wall-time facility. Returns an empty list if unavailable
  # (e.g. wall-time tracking not enabled), avoiding crashes on odd setups.
  defp scheduler_utilization do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined ->
        []

      wall_times when is_list(wall_times) ->
        wall_times
        |> Enum.map(fn {_id, active, total} ->
          if total > 0, do: active / total * 100.0, else: 0.0
        end)
    end
  rescue
    _ -> []
  end

  # Best-effort thermal reading. On Linux systems this reads the first
  # available thermal zone under /sys/class/thermal. Returns nil (rather
  # than raising) on platforms without this interface, e.g. macOS/Windows
  # or containers without sysfs mounted.
  defp read_temperature do
    thermal_glob = "/sys/class/thermal/thermal_zone*/temp"

    case Path.wildcard(thermal_glob) do
      [] ->
        nil

      [first | _] ->
        case File.read(first) do
          {:ok, contents} ->
            contents
            |> String.trim()
            |> String.to_integer()
            # sysfs reports millidegrees Celsius
            |> Kernel./(1000.0)

          {:error, _} ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  # Compares the newest sample against the previous one and emits
  # :telemetry events for memory and thermal spikes when thresholds
  # are exceeded. This lets external instrumentation (e.g. StatsD
  # exporters, log aggregators) react to anomalies in near real time.
  defp maybe_emit_spikes(%State{last_sample: nil}, _new_sample), do: :ok

  defp maybe_emit_spikes(%State{last_sample: prev} = state, new_sample) do
    memory_delta = new_sample.memory_total_bytes - prev.memory_total_bytes

    if memory_delta >= state.memory_spike_threshold_bytes do
      :telemetry.execute(
        [:stress_synth, :metrics_collector, :memory_spike],
        %{delta_bytes: memory_delta, total_bytes: new_sample.memory_total_bytes},
        %{previous: prev, current: new_sample}
      )

      Logger.warning(
        "MetricsCollector: memory spike detected (+#{div(memory_delta, 1024 * 1024)} MB)"
      )
    end

    if is_number(new_sample.temperature_c) and
         new_sample.temperature_c >= state.temp_spike_threshold_c do
      :telemetry.execute(
        [:stress_synth, :metrics_collector, :thermal_spike],
        %{temperature_c: new_sample.temperature_c},
        %{sample: new_sample}
      )

      Logger.warning(
        "MetricsCollector: thermal spike detected (#{new_sample.temperature_c}C)"
      )
    end

    :ok
  rescue
    # :telemetry may not be started in some minimal environments; never
    # let instrumentation failures crash the polling loop.
    _ -> :ok
  end

  # Computes basic min/max/avg statistics for memory and (when present)
  # temperature across the whole buffer. Returns an empty map if the
  # buffer has no samples yet.
  defp compute_stats([]), do: %{}

  defp compute_stats(buffer) do
    memory_values = Enum.map(buffer, & &1.memory_total_bytes)

    temp_values =
      buffer
      |> Enum.map(& &1.temperature_c)
      |> Enum.filter(&is_number/1)

    %{
      sample_count: length(buffer),
      memory_total_bytes: %{
        min: Enum.min(memory_values),
        max: Enum.max(memory_values),
        avg: Enum.sum(memory_values) / length(memory_values)
      },
      temperature_c: temp_stats(temp_values),
      process_count_max: buffer |> Enum.map(& &1.process_count) |> Enum.max()
    }
  end

  defp temp_stats([]), do: nil

  defp temp_stats(values) do
    %{
      min: Enum.min(values),
      max: Enum.max(values),
      avg: Enum.sum(values) / length(values)
    }
  end
end
