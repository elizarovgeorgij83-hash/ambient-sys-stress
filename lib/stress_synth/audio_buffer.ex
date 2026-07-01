defmodule StressSynth.AudioBuffer do
  @moduledoc """
  `StressSynth.AudioBuffer` is a GenServer-based ring/queue buffer that stores
  pre-generated floating-point PCM audio blocks (chunks) so that a downstream
  audio sink (sound card, network stream, etc.) can pull data without ever
  stalling -- i.e. "latency-free streaming".

  The buffer decouples the *producer* (a synthesis engine that renders PCM
  blocks, possibly at irregular intervals or in bursts) from the *consumer*
  (a real-time audio callback that must always have data ready). It supports:

    * Bounded capacity with back-pressure (producers can be told to wait
      when the buffer is full, or blocks can be dropped depending on the
      configured overflow strategy).
    * Watermark-based signalling: consumers/producers can be notified when
      the buffer level crosses configured low/high watermarks, allowing a
      producer to start rendering more audio *before* the buffer runs dry.
    * O(1) enqueue/dequeue via `:queue`.
    * Frame-accurate accounting (blocks may have arbitrary sample counts).

  ## PCM block format

  Each stored block is a tuple `{samples, metadata}` where:

    * `samples` is a list or binary of IEEE-754 floats representing PCM
      samples (interleaved if multi-channel), OR a `Nx`-free plain
      `[float]` list -- the module is agnostic to the exact representation
      as long as producers/consumers agree, but a `sample_count/1` helper
      is provided for both lists and binaries (32-bit floats packed as
      native-endian `f32`).
    * `metadata` is a map that may contain `:channels`, `:sample_rate`,
      `:timestamp` and other producer-defined fields.

  ## Example

      {:ok, buf} = StressSynth.AudioBuffer.start_link(capacity: 32)

      # producer thread
      :ok = StressSynth.AudioBuffer.push(buf, samples, %{channels: 2, sample_rate: 48_000})

      # consumer / audio callback
      case StressSynth.AudioBuffer.pop(buf) do
        {:ok, {samples, _meta}} -> play(samples)
        :empty -> play_silence()
      end
  """

  use GenServer
  require Logger

  @typedoc "A single rendered PCM block plus its metadata."
  @type block :: {samples :: [float()] | binary(), metadata :: map()}

  @typedoc "Strategy applied when `push/2` is called on a full buffer."
  @type overflow_strategy :: :block | :drop_oldest | :drop_newest | :error

  @typedoc "Options accepted by `start_link/1`."
  @type option ::
          {:name, GenServer.name()}
          | {:capacity, pos_integer()}
          | {:overflow, overflow_strategy()}
          | {:low_watermark, non_neg_integer()}
          | {:high_watermark, non_neg_integer()}
          | {:notify, pid() | nil}

  defmodule State do
    @moduledoc false
    defstruct queue: :queue.new(),
              # number of blocks currently stored
              count: 0,
              # total sample count currently buffered (for finer-grained
              # watermark decisions than block count alone)
              sample_total: 0,
              capacity: 64,
              overflow: :drop_oldest,
              low_watermark: 8,
              high_watermark: 48,
              # process to notify (via message) on watermark crossings
              notify: nil,
              # last watermark state we notified about, to avoid spamming
              last_signal: :none,
              # queue of {from, samples, metadata} waiting to be enqueued
              # when overflow == :block and buffer is full
              waiters: :queue.new()
  end

  ## ---------------------------------------------------------------------
  ## Public API
  ## ---------------------------------------------------------------------

  @doc """
  Starts the audio buffer process.

  ## Options

    * `:name` - optional GenServer name registration.
    * `:capacity` - max number of blocks stored (default: `64`).
    * `:overflow` - what to do when `push/2` is called while full:
      `:block` (caller waits until space is available), `:drop_oldest`
      (default), `:drop_newest`, or `:error` (returns `{:error, :full}`).
    * `:low_watermark` - block count below which a `:low` signal is sent
      to `:notify` (default: `capacity / 8`, minimum 1).
    * `:high_watermark` - block count above which a `:high` signal is sent
      to `:notify` (default: `capacity * 3 / 4`).
    * `:notify` - a pid that will receive
      `{:audio_buffer, :low | :high | :empty | :full}` messages when the
      corresponding watermark is crossed. Defaults to `nil` (no notifications).
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc """
  Pushes a new PCM block onto the buffer.

  `samples` may be a list of floats or a packed binary. `metadata` is any
  map describing the block (channels, sample_rate, timestamp, etc.).

  Behaviour on a full buffer depends on the `:overflow` option given at
  start time. Returns `:ok`, or `{:error, :full}` if the strategy is
  `:error`.
  """
  @spec push(GenServer.server(), [float()] | binary(), map()) ::
          :ok | {:error, :full}
  def push(server, samples, metadata \\ %{}) do
    GenServer.call(server, {:push, samples, metadata}, :infinity)
  end

  @doc """
  Pops the oldest block from the buffer.

  Returns `{:ok, block}` or `:empty` if there is nothing buffered -- the
  consumer should typically fall back to emitting silence in that case
  rather than blocking, to keep audio latency-free.
  """
  @spec pop(GenServer.server()) :: {:ok, block()} | :empty
  def pop(server) do
    GenServer.call(server, :pop)
  end

  @doc """
  Peeks at the oldest block without removing it from the buffer.
  """
  @spec peek(GenServer.server()) :: {:ok, block()} | :empty
  def peek(server) do
    GenServer.call(server, :peek)
  end

  @doc """
  Returns the current number of buffered blocks.
  """
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server) do
    GenServer.call(server, :count)
  end

  @doc """
  Returns the total number of samples currently buffered across all blocks.
  """
  @spec sample_total(GenServer.server()) :: non_neg_integer()
  def sample_total(server) do
    GenServer.call(server, :sample_total)
  end

  @doc """
  Drops all buffered blocks immediately (e.g. on seek / stop / underrun
  recovery).
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server) do
    GenServer.call(server, :flush)
  end

  @doc """
  Returns `true` if the buffer currently holds no blocks.
  """
  @spec empty?(GenServer.server()) :: boolean()
  def empty?(server), do: count(server) == 0

  @doc """
  Returns `true` if the buffer is at (or above) capacity.
  """
  @spec full?(GenServer.server()) :: boolean()
  def full?(server) do
    GenServer.call(server, :full?)
  end

  @doc """
  Utility: returns number of samples in a block's `samples` field, whether
  it is stored as a list of floats or a binary of native-endian 32-bit
  floats.
  """
  @spec sample_count([float()] | binary()) :: non_neg_integer()
  def sample_count(samples) when is_list(samples), do: length(samples)
  def sample_count(samples) when is_binary(samples), do: div(byte_size(samples), 4)

  ## ---------------------------------------------------------------------
  ## GenServer callbacks
  ## ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, 64)

    state = %State{
      capacity: capacity,
      overflow: Keyword.get(opts, :overflow, :drop_oldest),
      low_watermark: Keyword.get(opts, :low_watermark, max(1, div(capacity, 8))),
      high_watermark: Keyword.get(opts, :high_watermark, div(capacity * 3, 4)),
      notify: Keyword.get(opts, :notify, nil)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:push, samples, metadata}, from, %State{count: c, capacity: cap} = state)
      when c < cap do
    state = do_enqueue(state, samples, metadata)
    {:reply, :ok, state}
  end

  # Buffer is full -- apply overflow strategy.
  def handle_call({:push, samples, metadata}, from, %State{overflow: :drop_oldest} = state) do
    {_dropped, state} = do_dequeue(state)
    state = do_enqueue(state, samples, metadata)
    {:reply, :ok, state}
  end

  def handle_call({:push, _samples, _metadata}, _from, %State{overflow: :drop_newest} = state) do
    # Silently discard the incoming block; buffer contents unchanged.
    {:reply, :ok, state}
  end

  def handle_call({:push, _samples, _metadata}, _from, %State{overflow: :error} = state) do
    {:reply, {:error, :full}, state}
  end

  def handle_call({:push, samples, metadata}, from, %State{overflow: :block} = state) do
    # Park the caller until room becomes available (freed up by a pop).
    waiters = :queue.in({from, samples, metadata}, state.waiters)
    {:noreply, %{state | waiters: waiters}}
  end

  def handle_call(:pop, _from, %State{count: 0} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:pop, _from, state) do
    {block, state} = do_dequeue(state)

    # If there are queued writers (overflow == :block) and room has opened
    # up, admit the oldest waiter now.
    state = maybe_admit_waiter(state)

    {:reply, {:ok, block}, state}
  end

  def handle_call(:peek, _from, %State{count: 0} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:peek, _from, %State{queue: q} = state) do
    {{:value, block}, _} = :queue.out(q)
    {:reply, {:ok, block}, state}
  end

  def handle_call(:count, _from, %State{count: c} = state) do
    {:reply, c, state}
  end

  def handle_call(:sample_total, _from, %State{sample_total: t} = state) do
    {:reply, t, state}
  end

  def handle_call(:full?, _from, %State{count: c, capacity: cap} = state) do
    {:reply, c >= cap, state}
  end

  def handle_call(:flush, _from, state) do
    # Release anyone waiting on a blocked push -- their data is discarded,
    # matching the semantics of a hard flush (e.g. seek/stop).
    :queue.to_list(state.waiters)
    |> Enum.each(fn {from, _s, _m} -> GenServer.reply(from, :ok) end)

    new_state = %State{
      state
      | queue: :queue.new(),
        count: 0,
        sample_total: 0,
        waiters: :queue.new(),
        last_signal: :none
    }

    {:reply, :ok, new_state}
  end

  ## ---------------------------------------------------------------------
  ## Internal helpers
  ## ---------------------------------------------------------------------

  # Enqueues a block, updates accounting, and emits watermark signals.
  defp do_enqueue(%State{queue: q, count: c, sample_total: t} = state, samples, metadata) do
    n = sample_count(samples)
    new_queue = :queue.in({samples, metadata}, q)

    %{state | queue: new_queue, count: c + 1, sample_total: t + n}
    |> maybe_signal()
  end

  # Dequeues the oldest block, updates accounting, and emits watermark
  # signals. Returns `{block, new_state}`.
  defp do_dequeue(%State{queue: q, count: c, sample_total: t} = state) do
    {{:value, {samples, _metadata} = block}, new_queue} = :queue.out(q)
    n = sample_count(samples)

    new_state =
      %{state | queue: new_queue, count: c - 1, sample_total: max(t - n, 0)}
      |> maybe_signal()

    {block, new_state}
  end

  # If overflow strategy is :block and there's a parked writer, and the
  # buffer now has room, admit the oldest waiter's block into the queue
  # and reply :ok to unblock its caller.
  defp maybe_admit_waiter(%State{count: c, capacity: cap, waiters: w} = state)
       when c < cap do
    case :queue.out(w) do
      {{:value, {from, samples, metadata}}, rest} ->
        state = %{state | waiters: rest}
        state = do_enqueue(state, samples, metadata)
        GenServer.reply(from, :ok)
        state

      {:empty, _} ->
        state
    end
  end

  defp maybe_admit_waiter(state), do: state

  # Emits a `{:audio_buffer, signal}` message to the `:notify` pid (if
  # any) whenever the buffer level crosses a watermark boundary, avoiding
  # duplicate messages for the same signal in a row.
  defp maybe_signal(%State{notify: nil} = state), do: state

  defp maybe_signal(%State{count: c, capacity: cap, low_watermark: low, high_watermark: high} = state) do
    signal =
      cond do
        c == 0 -> :empty
        c >= cap -> :full
        c <= low -> :low
        c >= high -> :high
        true -> :normal
      end

    state =
      if signal != state.last_signal and signal != :normal do
        send(state.notify, {:audio_buffer, signal})
        %{state | last_signal: signal}
      else
        if signal == :normal do
          %{state | last_signal: :normal}
        else
          state
        end
      end

    state
  end
end
