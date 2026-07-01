defmodule StressSynth.MetricsCollectorTest do
  @moduledoc """
  Stress-test suite for `StressSynth.MetricsCollector`.

  These tests spin up a large number of mock "worker" processes that
  simulate metrics sources under maximum system load, and verify that the
  MetricsCollector's polling loop keeps functioning correctly:
    * it does not miss scheduled polls,
    * it does not crash or deadlock when workers are slow, unresponsive,
      or crashing,
    * it correctly aggregates metrics even when messages arrive out of
      order or in large bursts,
    * it recovers gracefully when mock processes die and are restarted.

  We use plain processes (spawned via `spawn_link`/`Task`) as mocks rather
  than a mocking library, since we need fine control over timing and
  failure injection to simulate real load conditions.
  """

  use ExUnit.Case, async: false

  alias StressSynth.MetricsCollector

  # Number of mock worker processes to simulate under "maximum load".
  @worker_count 500

  # How many polling cycles to run during the stress test.
  @poll_cycles 20

  # Interval (ms) between poll cycles -- kept small to maximize pressure.
  @poll_interval 10

  setup do
    # Start a fresh collector for every test so state does not leak between
    # test cases. We pass a short poll interval to make the collector poll
    # aggressively during the test run.
    {:ok, pid} =
      MetricsCollector.start_link(
        name: nil,
        poll_interval: @poll_interval,
        max_queue: @worker_count * 4
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    {:ok, collector: pid}
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Spawns a mock worker process that responds to `:collect_metrics` calls
  # sent from the collector. `behavior` controls how the mock reacts:
  #
  #   :normal    -> replies immediately with a fake metric payload
  #   :slow      -> sleeps for `delay_ms` before replying (simulates load)
  #   :flaky     -> randomly crashes instead of replying
  #   :dead      -> exits immediately after registration (simulates a
  #                 worker that died before the collector could poll it)
  defp spawn_mock_worker(behavior, opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, 5)
    id = Keyword.get(opts, :id, make_ref())

    spawn_link(fn ->
      mock_worker_loop(behavior, id, delay_ms)
    end)
  end

  defp mock_worker_loop(:dead, _id, _delay), do: :ok

  defp mock_worker_loop(behavior, id, delay_ms) do
    receive do
      {:collect_metrics, from} ->
        case behavior do
          :normal ->
            send(from, {:metrics, id, fake_metric_payload(id)})
            mock_worker_loop(behavior, id, delay_ms)

          :slow ->
            Process.sleep(delay_ms)
            send(from, {:metrics, id, fake_metric_payload(id)})
            mock_worker_loop(behavior, id, delay_ms)

          :flaky ->
            if :rand.uniform() < 0.3 do
              # Simulate a crash under load -- the collector must survive
              # this without losing track of other workers.
              exit(:mock_worker_crash)
            else
              send(from, {:metrics, id, fake_metric_payload(id)})
              mock_worker_loop(behavior, id, delay_ms)
            end
        end
    after
      1_000 ->
        # No poll arrived in time; keep looping so we don't leak processes
        # that linger forever waiting on a message that never comes.
        mock_worker_loop(behavior, id, delay_ms)
    end
  end

  defp fake_metric_payload(id) do
    %{
      worker_id: id,
      cpu: :rand.uniform(100),
      memory: :rand.uniform(4096),
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  # Registers a batch of mock workers with the collector under test.
  defp register_workers(collector, workers) do
    Enum.each(workers, fn {id, pid} ->
      :ok = MetricsCollector.register_source(collector, id, pid)
    end)
  end

  # Waits (with a timeout) until the given predicate on the collector's
  # state becomes true. Used to avoid brittle `Process.sleep/1` based
  # assertions when polling under load.
  defp wait_until(fun, timeout_ms \\ 5_000, interval_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_until(fun, deadline, interval_ms)
  end

  defp do_wait_until(fun, deadline, interval_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(interval_ms)
        do_wait_until(fun, deadline, interval_ms)
      end
    end
  end

  # ---------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------

  describe "polling under maximum load with all-healthy workers" do
    test "collector keeps polling and aggregating metrics for all workers", %{
      collector: collector
    } do
      workers =
        for i <- 1..@worker_count do
          {i, spawn_mock_worker(:normal)}
        end

      register_workers(collector, workers)

      # Force several poll cycles to happen back to back to simulate
      # sustained maximum load.
      Enum.each(1..@poll_cycles, fn _ ->
        MetricsCollector.force_poll(collector)
        Process.sleep(@poll_interval)
      end)

      assert :ok =
               wait_until(fn ->
                 stats = MetricsCollector.stats(collector)
                 stats.tracked_sources == @worker_count and stats.last_poll_errors == 0
               end)

      stats = MetricsCollector.stats(collector)

      assert stats.tracked_sources == @worker_count
      assert stats.last_poll_errors == 0
      assert stats.total_polls >= @poll_cycles

      # Every worker must have contributed at least one metric sample.
      snapshot = MetricsCollector.snapshot(collector)
      assert map_size(snapshot) == @worker_count

      Enum.each(workers, fn {id, _pid} ->
        assert Map.has_key?(snapshot, id)
        assert is_map(snapshot[id])
        assert snapshot[id].cpu >= 0
      end)
    end
  end

  describe "polling under maximum load with slow workers" do
    test "collector does not block on slow responders and still finishes cycles", %{
      collector: collector
    } do
      # Half of the workers are slow (up to 50ms delay), the rest respond
      # immediately. This simulates uneven load across the system.
      workers =
        for i <- 1..@worker_count do
          behavior = if rem(i, 2) == 0, do: :slow, else: :normal
          delay = if behavior == :slow, do: Enum.random(10..50), else: 0
          {i, spawn_mock_worker(behavior, delay_ms: delay, id: i)}
        end

      register_workers(collector, workers)

      start_time = System.monotonic_time(:millisecond)

      Enum.each(1..@poll_cycles, fn _ ->
        MetricsCollector.force_poll(collector)
        Process.sleep(@poll_interval)
      end)

      # Give slow workers time to flush their delayed replies.
      assert :ok =
               wait_until(
                 fn ->
                   stats = MetricsCollector.stats(collector)
                   stats.total_polls >= @poll_cycles
                 end,
                 10_000
               )

      elapsed = System.monotonic_time(:millisecond) - start_time

      # The collector must not have blocked synchronously on every slow
      # worker in sequence -- if it did, elapsed time would be on the
      # order of @worker_count * 50ms which is far larger than what we
      # allow here.
      assert elapsed < @worker_count * 25

      stats = MetricsCollector.stats(collector)
      assert stats.tracked_sources == @worker_count
    end
  end

  describe "polling under maximum load with flaky/crashing workers" do
    test "collector survives repeated worker crashes without losing healthy sources", %{
      collector: collector
    } do
      workers =
        for i <- 1..@worker_count do
          behavior = if rem(i, 5) == 0, do: :flaky, else: :normal
          {i, spawn_mock_worker(behavior, id: i)}
        end

      register_workers(collector, workers)

      Enum.each(1..@poll_cycles, fn _ ->
        MetricsCollector.force_poll(collector)
        Process.sleep(@poll_interval)
      end)

      assert :ok =
               wait_until(fn ->
                 stats = MetricsCollector.stats(collector)
                 stats.total_polls >= @poll_cycles
               end)

      stats = MetricsCollector.stats(collector)

      # Some poll errors are expected due to the flaky workers crashing,
      # but the collector process itself must remain alive and responsive.
      assert Process.alive?(collector)
      assert stats.total_polls >= @poll_cycles
      assert stats.last_poll_errors >= 0

      # Non-flaky ("normal") workers must still be fully represented in
      # the aggregated snapshot despite crashes elsewhere in the system.
      snapshot = MetricsCollector.snapshot(collector)

      normal_ids =
        workers
        |> Enum.filter(fn {i, _pid} -> rem(i, 5) != 0 end)
        |> Enum.map(fn {i, _pid} -> i end)

      Enum.each(normal_ids, fn id ->
        assert Map.has_key?(snapshot, id),
               "expected snapshot to contain metrics for healthy worker #{id}"
      end)
    end
  end

  describe "polling under maximum load with dead workers registered" do
    test "collector marks dead sources without crashing the polling loop", %{
      collector: collector
    } do
      dead_workers =
        for i <- 1..50 do
          pid = spawn_mock_worker(:dead)
          # Ensure the mock process has actually exited before we register
          # it, to accurately simulate a worker that died before polling.
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1_000 -> flunk("mock dead worker did not exit in time")
          end

          {i, pid}
        end

      healthy_workers =
        for i <- 51..(@worker_count + 50) do
          {i, spawn_mock_worker(:normal, id: i)}
        end

      register_workers(collector, dead_workers ++ healthy_workers)

      Enum.each(1..@poll_cycles, fn _ ->
        MetricsCollector.force_poll(collector)
        Process.sleep(@poll_interval)
      end)

      assert :ok =
               wait_until(fn ->
                 stats = MetricsCollector.stats(collector)
                 stats.total_polls >= @poll_cycles
               end)

      assert Process.alive?(collector)

      stats = MetricsCollector.stats(collector)
      assert stats.dead_sources >= 50
      assert stats.tracked_sources == @worker_count + 50

      # Healthy workers must still be polled correctly despite dead ones
      # occupying slots in the source registry.
      snapshot = MetricsCollector.snapshot(collector)

      Enum.each(healthy_workers, fn {id, _pid} ->
        assert Map.has_key?(snapshot, id)
      end)
    end
  end

  describe "burst polling / backpressure" do
    test "collector applies backpressure and does not exceed max_queue under a burst of forced polls",
         %{collector: collector} do
      workers =
        for i <- 1..@worker_count do
          {i, spawn_mock_worker(:normal, id: i)}
        end

      register_workers(collector, workers)

      # Fire off a burst of forced polls with no delay between them,
      # simulating a spike far beyond the configured poll_interval.
      burst_size = 200

      tasks =
        for _ <- 1..burst_size do
          Task.async(fn -> MetricsCollector.force_poll(collector) end)
        end

      Enum.each(tasks, &Task.await(&1, 5_000))

      assert :ok =
               wait_until(fn ->
                 Process.alive?(collector)
               end)

      stats = MetricsCollector.stats(collector)

      # The internal queue must never have grown past the configured
      # max_queue, proving the collector applies backpressure instead of
      # accumulating unbounded work under a burst.
      assert stats.max_observed_queue_len <= @worker_count * 4
      assert stats.tracked_sources == @worker_count
    end
  end

  describe "graceful shutdown under load" do
    test "collector shuts down cleanly even while polling is actively in progress", %{
      collector: collector
    } do
      workers =
        for i <- 1..@worker_count do
          {i, spawn_mock_worker(:slow, delay_ms: Enum.random(5..30), id: i)}
        end

      register_workers(collector, workers)

      # Kick off polling and immediately request a stop -- this exercises
      # the shutdown path while poll responses are still in flight.
      MetricsCollector.force_poll(collector)

      assert :ok = GenServer.stop(collector, :normal, 2_000)
      refute Process.alive?(collector)
    end
  end
end
