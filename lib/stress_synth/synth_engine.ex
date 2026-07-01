defmodule StressSynth.SynthEngine do
  @moduledoc """
  `StressSynth.SynthEngine` transforms live system telemetry — CPU cycle
  counts and temperature readings — into harmonic audio waveforms and
  digital filter coefficients.

  The core idea is to treat the CPU as an oscillator: its cycle count
  drives a fundamental frequency, while temperature acts as a slowly
  varying modulation source (timbre / brightness). The resulting signal
  can be rendered to PCM samples and shaped with a resonant low-pass
  filter whose cutoff also reacts to thermal load.

  All computations are pure and side-effect free so they can be tested,
  benchmarked, and composed freely.
  """

  @typedoc "A single audio sample in the range [-1.0, 1.0]"
  @type sample :: float()

  @typedoc "Biquad filter coefficients: {b0, b1, b2, a1, a2}"
  @type biquad_coeffs :: {float(), float(), float(), float(), float()}

  # ---------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------

  # Standard CD-quality sample rate, used for all time-domain calculations.
  @sample_rate 44_100

  # Baseline CPU clock (Hz) used to normalize cycle counts into a musical
  # frequency range. Real CPUs run in the GHz range; we scale this down
  # by a configurable divisor so the resulting audio frequency lands in
  # the audible spectrum (roughly 20 Hz - 20 kHz).
  @base_clock_hz 3_000_000_000

  # The frequency divisor maps GHz-scale cycles down to audible tones.
  # Chosen empirically so that typical desktop CPU speeds (2-5 GHz)
  # produce frequencies in the 80-400 Hz range (bass/mid register).
  @frequency_divisor 20_000_000

  # Minimum and maximum fundamental frequency (Hz) we allow, to keep
  # generated audio within a sane and pleasant range regardless of
  # extreme cycle counts.
  @min_frequency 20.0
  @max_frequency 18_000.0

  # Reference temperature range (Celsius) used to map thermal readings
  # onto a 0.0 - 1.0 modulation index.
  @min_temp_c 20.0
  @max_temp_c 100.0

  # Number of harmonic partials to synthesize above the fundamental.
  @harmonic_count 6

  # ---------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------

  @doc """
  Converts a raw CPU cycle count (cycles observed within one sampling
  interval) into a fundamental frequency in Hz, clamped to an audible
  range.

  ## Examples

      iex> StressSynth.SynthEngine.cycles_to_frequency(60_000_000)
      3000.0

  """
  @spec cycles_to_frequency(non_neg_integer()) :: float()
  def cycles_to_frequency(cycles) when is_integer(cycles) and cycles >= 0 do
    raw_freq = cycles / @frequency_divisor

    raw_freq
    |> max(@min_frequency)
    |> min(@max_frequency)
  end

  @doc """
  Normalizes a temperature reading (Celsius) into a modulation index in
  the range [0.0, 1.0]. Values outside the configured min/max bounds are
  clamped.

  ## Examples

      iex> StressSynth.SynthEngine.temperature_to_modulation(60.0)
      0.5

  """
  @spec temperature_to_modulation(number()) :: float()
  def temperature_to_modulation(temp_c) when is_number(temp_c) do
    clamped = temp_c |> max(@min_temp_c) |> min(@max_temp_c)
    (clamped - @min_temp_c) / (@max_temp_c - @min_temp_c)
  end

  @doc """
  Generates a harmonic waveform buffer of `duration_seconds` based on the
  given CPU cycle count and temperature reading.

  The fundamental frequency is derived from `cycles_to_frequency/1`. The
  temperature modulation index controls both the number of audible
  harmonics (brightness) and a slow amplitude tremolo, simulating how
  thermal throttling introduces audible "roughness" into the signal.

  Returns a list of `sample/0` floats in the range [-1.0, 1.0].

  ## Examples

      iex> samples = StressSynth.SynthEngine.generate_waveform(50_000_000, 45.0, 0.01)
      iex> length(samples) > 0
      true

  """
  @spec generate_waveform(non_neg_integer(), number(), float()) :: [sample()]
  def generate_waveform(cycles, temp_c, duration_seconds)
      when is_integer(cycles) and cycles >= 0 and is_number(temp_c) and duration_seconds > 0 do
    fundamental = cycles_to_frequency(cycles)
    modulation = temperature_to_modulation(temp_c)

    total_samples = round(duration_seconds * @sample_rate)

    # Higher temperature => more active harmonics => "brighter"/harsher tone,
    # simulating audible distortion under thermal stress.
    active_harmonics = 1 + round(modulation * @harmonic_count)

    # Tremolo (slow amplitude wobble) frequency increases with heat, giving
    # a sense of instability as the system gets hotter.
    tremolo_freq = 0.5 + modulation * 8.0

    0..(total_samples - 1)
    |> Enum.map(fn n ->
      t = n / @sample_rate
      synthesize_sample(t, fundamental, active_harmonics, modulation, tremolo_freq)
    end)
  end

  @doc """
  Computes a set of biquad low-pass filter coefficients whose cutoff
  frequency and resonance (Q) are derived from the current CPU frequency
  and temperature.

  As temperature rises, the cutoff frequency is pulled down (simulating
  a muffled, "throttled" sound) and the resonance (Q) increases slightly
  to add character/emphasis near the cutoff.

  Returns a `biquad_coeffs/0` tuple `{b0, b1, b2, a1, a2}` implementing
  the standard RBJ Audio EQ Cookbook low-pass filter, normalized so that
  `a0 == 1.0` (already divided through).

  ## Examples

      iex> {b0, b1, b2, a1, a2} = StressSynth.SynthEngine.compute_filter_coefficients(50_000_000, 70.0)
      iex> is_float(b0) and is_float(a1) and is_float(a2)
      true

  """
  @spec compute_filter_coefficients(non_neg_integer(), number()) :: biquad_coeffs()
  def compute_filter_coefficients(cycles, temp_c)
      when is_integer(cycles) and cycles >= 0 and is_number(temp_c) do
    fundamental = cycles_to_frequency(cycles)
    modulation = temperature_to_modulation(temp_c)

    # Base cutoff sits above the fundamental so the tone isn't muted at
    # rest; as heat rises, the cutoff drops toward the fundamental,
    # simulating thermal throttling "muffling" the signal.
    max_cutoff = min(fundamental * 8.0, @max_frequency)
    min_cutoff = max(fundamental * 1.5, @min_frequency)

    cutoff = max_cutoff - modulation * (max_cutoff - min_cutoff)

    # Resonance grows mildly with heat (0.707 = Butterworth / no resonance
    # peak, up to ~2.5 for a pronounced peak).
    q = 0.707 + modulation * 1.8

    rbj_lowpass(cutoff, q, @sample_rate)
  end

  @doc """
  Applies the given biquad filter coefficients to a list of input samples
  using the standard Direct Form I difference equation:

      y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]

  Returns the filtered sample list, same length as input.
  """
  @spec apply_filter([sample()], biquad_coeffs()) :: [sample()]
  def apply_filter(samples, {b0, b1, b2, a1, a2}) when is_list(samples) do
    initial_state = %{x1: 0.0, x2: 0.0, y1: 0.0, y2: 0.0}

    {filtered_reversed, _final_state} =
      Enum.reduce(samples, {[], initial_state}, fn x0, {acc, state} ->
        %{x1: x1, x2: x2, y1: y1, y2: y2} = state

        y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2

        new_state = %{x1: x0, x2: x1, y1: y0, y2: y1}
        {[y0 | acc], new_state}
      end)

    Enum.reverse(filtered_reversed)
  end

  @doc """
  Convenience pipeline: given raw cycles, temperature, and a desired
  duration, generates the harmonic waveform and immediately applies the
  matching thermal low-pass filter.

  Returns the fully processed sample list.
  """
  @spec render(non_neg_integer(), number(), float()) :: [sample()]
  def render(cycles, temp_c, duration_seconds) do
    samples = generate_waveform(cycles, temp_c, duration_seconds)
    coeffs = compute_filter_coefficients(cycles, temp_c)
    apply_filter(samples, coeffs)
  end

  @doc """
  Estimates CPU cycles for a given clock speed (Hz) and elapsed time
  (seconds). Useful for feeding synthetic/test data into the engine
  when only clock speed is known rather than a raw cycle counter delta.

  ## Examples

      iex> StressSynth.SynthEngine.estimate_cycles(2_500_000_000, 0.02)
      50000000

  """
  @spec estimate_cycles(number(), number()) :: non_neg_integer()
  def estimate_cycles(clock_hz, elapsed_seconds)
      when is_number(clock_hz) and clock_hz >= 0 and is_number(elapsed_seconds) and
             elapsed_seconds >= 0 do
    round(clock_hz * elapsed_seconds)
  end

  @doc """
  Returns the base clock speed constant (Hz) used as a reference point
  for cycle-to-frequency scaling.
  """
  @spec base_clock_hz() :: pos_integer()
  def base_clock_hz, do: @base_clock_hz

  @doc """
  Returns the configured audio sample rate (Hz).
  """
  @spec sample_rate() :: pos_integer()
  def sample_rate, do: @sample_rate

  # ---------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------

  # Synthesizes a single time-domain sample as a sum of harmonic sine
  # partials, each attenuated by 1/n (a sawtooth-like decay), further
  # shaped by a slow tremolo envelope driven by temperature.
  @spec synthesize_sample(float(), float(), pos_integer(), float(), float()) :: sample()
  defp synthesize_sample(t, fundamental, harmonics, modulation, tremolo_freq) do
    two_pi = 2 * :math.pi()

    harmonic_sum =
      1..harmonics
      |> Enum.reduce(0.0, fn n, acc ->
        # 1/n amplitude decay keeps higher harmonics quieter, avoiding
        # harsh aliasing-like buildup while still adding brightness.
        amplitude = 1.0 / n
        acc + amplitude * :math.sin(two_pi * fundamental * n * t)
      end)

    # Normalize by the harmonic series sum so overall amplitude stays
    # roughly bounded regardless of how many harmonics are active.
    normalization = harmonic_series_sum(harmonics)
    base_signal = harmonic_sum / normalization

    # Tremolo: slow sinusoidal amplitude modulation, intensity scales
    # with temperature-derived modulation index.
    tremolo_depth = modulation * 0.3
    tremolo = 1.0 - tremolo_depth + tremolo_depth * :math.sin(two_pi * tremolo_freq * t)

    signal = base_signal * tremolo

    # Final clamp for safety, in case of floating point overshoot.
    signal |> max(-1.0) |> min(1.0)
  end

  # Sum of 1/1 + 1/2 + ... + 1/n, used to normalize harmonic amplitude.
  @spec harmonic_series_sum(pos_integer()) :: float()
  defp harmonic_series_sum(n) do
    1..n
    |> Enum.reduce(0.0, fn i, acc -> acc + 1.0 / i end)
  end

  # Implements the RBJ Audio EQ Cookbook low-pass biquad filter design.
  # Reference: https://www.w3.org/audio/audio-eq-cookbook.html
  #
  # Given a cutoff frequency, Q factor, and sample rate, returns
  # normalized coefficients {b0, b1, b2, a1, a2} with a0 already
  # divided out (i.e. a0 == 1.0 implicitly).
  @spec rbj_lowpass(float(), float(), pos_integer()) :: biquad_coeffs()
  defp rbj_lowpass(cutoff_hz, q, sample_rate) do
    # Guard against invalid cutoff (must be < Nyquist and > 0).
    nyquist = sample_rate / 2.0
    safe_cutoff = cutoff_hz |> max(1.0) |> min(nyquist - 1.0)

    omega = 2 * :math.pi() * safe_cutoff / sample_rate
    sin_omega = :math.sin(omega)
    cos_omega = :math.cos(omega)
    alpha = sin_omega / (2 * q)

    b0_raw = (1 - cos_omega) / 2
    b1_raw = 1 - cos_omega
    b2_raw = (1 - cos_omega) / 2
    a0_raw = 1 + alpha
    a1_raw = -2 * cos_omega
    a2_raw = 1 - alpha

    # Normalize all coefficients by a0 so the difference equation can
    # assume a0 == 1.0.
    {
      b0_raw / a0_raw,
      b1_raw / a0_raw,
      b2_raw / a0_raw,
      a1_raw / a0_raw,
      a2_raw / a0_raw
    }
  end
end
