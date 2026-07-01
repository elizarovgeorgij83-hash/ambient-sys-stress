defmodule StressSynth.SynthEngineTest do
  @moduledoc """
  Stress / correctness test-suite for the `SynthEngine` module.

  These tests validate that hardware performance data (MIDI note numbers,
  pitch-bend wheel positions, cent-level fine tuning, LFO vibrato depth,
  and velocity-driven modulation) is translated by `SynthEngine` into
  mathematically correct audio output frequencies.

  The suite combines:

    * exact/closed-form assertions (equal-tempered tuning math),
    * numeric tolerance assertions for floating point rounding,
    * signal-based verification -- we actually render short PCM buffers
      with `SynthEngine.render/2` and measure the resulting fundamental
      frequency via zero-crossing analysis, to make sure the oscillator
      itself (not just the tuning math) is correct,
    * property-based (StreamData) stress testing across the full MIDI
      note range, pitch-bend range, and sample rates, to catch edge
      cases that example-based tests would miss.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SynthEngine

  # ---------------------------------------------------------------------
  # Constants / test fixtures
  # ---------------------------------------------------------------------

  # A4 = MIDI note 69 = 440 Hz is the universal tuning reference.
  @a4_midi_note 69
  @a4_frequency 440.0

  # Standard 12-tone equal temperament: each semitone is the 12th root of 2.
  @semitone_ratio :math.pow(2, 1 / 12)

  # Acceptable relative error (0.05%) when comparing rendered audio
  # frequency against the theoretical target -- accounts for zero-crossing
  # quantization at finite sample rates.
  @freq_rel_tolerance 0.0005

  # Common hardware sample rates we must support correctly.
  @sample_rates [22_050, 44_100, 48_000, 96_000]

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Standard equal-tempered frequency formula:
  #   f = 440 * 2 ^ ((note - 69) / 12)
  defp expected_frequency(midi_note) when is_number(midi_note) do
    @a4_frequency * :math.pow(2, (midi_note - @a4_midi_note) / 12)
  end

  # Cents are 1/100th of a semitone: f' = f * 2 ^ (cents / 1200)
  defp apply_cents_math(freq, cents) do
    freq * :math.pow(2, cents / 1200)
  end

  # Pitch bend is expressed as a normalized value in [-1.0, 1.0] mapped
  # onto +/- `range_semitones` semitones of frequency deviation.
  defp apply_bend_math(freq, bend, range_semitones) do
    freq * :math.pow(2, bend * range_semitones / 12)
  end

  # Measures the dominant frequency of a mono PCM sample buffer using a
  # zero-crossing counter. This is intentionally simple (no FFT
  # dependency) but accurate enough for single-oscillator sine/saw/square
  # test signals over a fixed analysis window.
  defp measure_frequency_by_zero_crossings(samples, sample_rate) when is_list(samples) do
    crossings =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> a <= 0 and b > 0 end)

    duration_seconds = length(samples) / sample_rate
    crossings / duration_seconds
  end

  # Renders `duration_ms` milliseconds of audio for the given note/opts
  # and returns the list of raw float samples in range [-1.0, 1.0].
  defp render_samples(midi_note, opts) do
    duration_ms = Keyword.get(opts, :duration_ms, 100)
    sample_rate = Keyword.get(opts, :sample_rate, 44_100)
    waveform = Keyword.get(opts, :waveform, :sine)

    SynthEngine.render(midi_note,
      duration_ms: duration_ms,
      sample_rate: sample_rate,
      waveform: waveform,
      cents: Keyword.get(opts, :cents, 0),
      pitch_bend: Keyword.get(opts, :pitch_bend, 0.0),
      pitch_bend_range: Keyword.get(opts, :pitch_bend_range, 2),
      velocity: Keyword.get(opts, :velocity, 100)
    )
  end

  # ---------------------------------------------------------------------
  # 1. Core tuning math -- MIDI note -> frequency
  # ---------------------------------------------------------------------

  describe "midi_to_frequency/1 basic tuning" do
    test "A4 (note 69) resolves to exactly 440 Hz" do
      assert_in_delta SynthEngine.midi_to_frequency(@a4_midi_note), @a4_frequency, 0.0001
    end

    test "middle C (note 60) resolves to ~261.63 Hz" do
      assert_in_delta SynthEngine.midi_to_frequency(60), 261.6256, 0.001
    end

    test "one octave up doubles the frequency" do
      base = SynthEngine.midi_to_frequency(60)
      octave_up = SynthEngine.midi_to_frequency(72)

      assert_in_delta octave_up, base * 2, 0.0001
    end

    test "one octave down halves the frequency" do
      base = SynthEngine.midi_to_frequency(60)
      octave_down = SynthEngine.midi_to_frequency(48)

      assert_in_delta octave_down, base / 2, 0.0001
    end

    test "adjacent semitones differ by the 12th root of 2" do
      for note <- 21..108 do
        f1 = SynthEngine.midi_to_frequency(note)
        f2 = SynthEngine.midi_to_frequency(note + 1)

        assert_in_delta f2 / f1, @semitone_ratio, 0.00001
      end
    end

    test "full piano range (MIDI 21-108) matches closed-form formula exactly" do
      for note <- 21..108 do
        expected = expected_frequency(note)
        actual = SynthEngine.midi_to_frequency(note)

        assert_in_delta actual, expected, expected * @freq_rel_tolerance
      end
    end
  end

  # ---------------------------------------------------------------------
  # 2. Fine tuning via cents
  # ---------------------------------------------------------------------

  describe "cents-based fine tuning" do
    test "0 cents leaves frequency unchanged" do
      base = SynthEngine.midi_to_frequency(60)
      tuned = SynthEngine.apply_cents(base, 0)

      assert_in_delta tuned, base, 0.0001
    end

    test "+100 cents equals exactly one semitone up" do
      base = SynthEngine.midi_to_frequency(60)
      next_semitone = SynthEngine.midi_to_frequency(61)

      tuned = SynthEngine.apply_cents(base, 100)

      assert_in_delta tuned, next_semitone, next_semitone * 0.0001
    end

    test "-100 cents equals exactly one semitone down" do
      base = SynthEngine.midi_to_frequency(60)
      prev_semitone = SynthEngine.midi_to_frequency(59)

      tuned = SynthEngine.apply_cents(base, -100)

      assert_in_delta tuned, prev_semitone, prev_semitone * 0.0001
    end

    test "cents mapping matches closed-form math across a wide sweep" do
      base = SynthEngine.midi_to_frequency(@a4_midi_note)

      for cents <- -1200..1200//25 do
        expected = apply_cents_math(base, cents)
        actual = SynthEngine.apply_cents(base, cents)

        assert_in_delta actual, expected, expected * @freq_rel_tolerance
      end
    end
  end

  # ---------------------------------------------------------------------
  # 3. Pitch bend wheel emulation (hardware controller input)
  # ---------------------------------------------------------------------

  describe "pitch bend hardware emulation" do
    test "bend of 0.0 leaves frequency unchanged" do
      base = SynthEngine.midi_to_frequency(60)
      bent = SynthEngine.apply_pitch_bend(base, 0.0, 2)

      assert_in_delta bent, base, 0.0001
    end

    test "full-up bend (+1.0) with 2-semitone range raises pitch by a whole tone" do
      base = SynthEngine.midi_to_frequency(60)
      whole_tone_up = SynthEngine.midi_to_frequency(62)

      bent = SynthEngine.apply_pitch_bend(base, 1.0, 2)

      assert_in_delta bent, whole_tone_up, whole_tone_up * 0.0005
    end

    test "full-down bend (-1.0) with 2-semitone range lowers pitch by a whole tone" do
      base = SynthEngine.midi_to_frequency(60)
      whole_tone_down = SynthEngine.midi_to_frequency(58)

      bent = SynthEngine.apply_pitch_bend(base, -1.0, 2)

      assert_in_delta bent, whole_tone_down, whole_tone_down * 0.0005
    end

    test "pitch bend is linear in semitone-log space across common hardware ranges" do
      base = SynthEngine.midi_to_frequency(@a4_midi_note)

      for range <- [1, 2, 3, 7, 12], bend <- [-1.0, -0.5, -0.25, 0.0, 0.25, 0.5, 1.0] do
        expected = apply_bend_math(base, bend, range)
        actual = SynthEngine.apply_pitch_bend(base, bend, range)

        assert_in_delta actual, expected, max(expected * @freq_rel_tolerance, 0.001)
      end
    end
  end

  # ---------------------------------------------------------------------
  # 4. Rendered audio output verification (signal-level correctness)
  # ---------------------------------------------------------------------

  describe "rendered audio output frequency (signal analysis)" do
    test "sine oscillator at A4 produces ~440 Hz measured output" do
      samples = render_samples(@a4_midi_note, waveform: :sine, duration_ms: 200)

      measured = measure_frequency_by_zero_crossings(samples, 44_100)

      assert_in_delta measured, @a4_frequency, @a4_frequency * 0.01
    end

    test "square oscillator preserves fundamental frequency" do
      samples = render_samples(60, waveform: :square, duration_ms: 200)
      expected = SynthEngine.midi_to_frequency(60)

      measured = measure_frequency_by_zero_crossings(samples, 44_100)

      assert_in_delta measured, expected, expected * 0.02
    end

    test "sawtooth oscillator preserves fundamental frequency" do
      samples = render_samples(60, waveform: :saw, duration_ms: 200)
      expected = SynthEngine.midi_to_frequency(60)

      measured = measure_frequency_by_zero_crossings(samples, 44_100)

      assert_in_delta measured, expected, expected * 0.02
    end

    test "rendered output respects cents fine-tuning end-to-end" do
      samples = render_samples(60, cents: 50, duration_ms: 200)
      expected = apply_cents_math(SynthEngine.midi_to_frequency(60), 50)

      measured = measure_frequency_by_zero_crossings(samples, 44_100)

      assert_in_delta measured, expected, expected * 0.02
    end

    test "rendered output respects pitch bend end-to-end" do
      samples =
        render_samples(60, pitch_bend: 0.5, pitch_bend_range: 2, duration_ms: 200)

      expected = apply_bend_math(SynthEngine.midi_to_frequency(60), 0.5, 2)

      measured = measure_frequency_by_zero_crossings(samples, 44_100)

      assert_in_delta measured, expected, expected * 0.02
    end

    test "sample rate does not affect the measured fundamental frequency" do
      for sample_rate <- @sample_rates do
        samples = render_samples(69, sample_rate: sample_rate, duration_ms: 200)

        measured = measure_frequency_by_zero_crossings(samples, sample_rate)

        assert_in_delta measured, @a4_frequency, @a4_frequency * 0.02,
          "sample_rate=#{sample_rate} produced incorrect frequency"
      end
    end

    test "output amplitude stays within the normalized [-1.0, 1.0] range" do
      samples = render_samples(60, waveform: :sine, duration_ms: 100)

      assert Enum.all?(samples, &(&1 >= -1.0 and &1 <= 1.0))
    end

    test "silence (velocity 0) produces a buffer of near-zero amplitude" do
      samples = render_samples(60, velocity: 0, duration_ms: 100)

      assert Enum.all?(samples, &(abs(&1) < 0.001))
    end
  end

  # ---------------------------------------------------------------------
  # 5. Vibrato / LFO modulation correctness
  # ---------------------------------------------------------------------

  describe "vibrato LFO modulation" do
    test "vibrato with zero depth does not alter the base frequency" do
      samples =
        SynthEngine.render(60,
          duration_ms: 200,
          sample_rate: 44_100,
          waveform: :sine,
          vibrato_rate_hz: 5.0,
          vibrato_depth_cents: 0
        )

      expected = SynthEngine.midi_to_frequency(60)
      measured = measure_frequency_by_zero_crossings(samples, 44_100)

      assert_in_delta measured, expected, expected * 0.02
    end

    test "vibrato oscillates the pitch symmetrically around the base frequency" do
      base = SynthEngine.midi_to_frequency(60)

      samples =
        SynthEngine.render(60,
          duration_ms: 500,
          sample_rate: 44_100,
          waveform: :sine,
          vibrato_rate_hz: 5.0,
          vibrato_depth_cents: 50
        )

      # Average frequency over a full LFO cycle should still be close to
      # the un-modulated base, since vibrato is symmetric.
      measured_avg = measure_frequency_by_zero_crossings(samples, 44_100)

      assert_in_delta measured_avg, base, base * 0.03
    end
  end

  # ---------------------------------------------------------------------
  # 6. Property-based stress testing across the full hardware input space
  # ---------------------------------------------------------------------

  describe "property-based stress tests" do
    property "midi_to_frequency/1 always matches the equal-tempered closed form" do
      check all(note <- integer(0..127), max_runs: 200) do
        expected = expected_frequency(note)
        actual = SynthEngine.midi_to_frequency(note)

        assert_in_delta actual, expected, max(expected * @freq_rel_tolerance, 1.0e-6)
      end
    end

    property "cents adjustment is monotonic with respect to sign" do
      check all(
              note <- integer(12..120),
              cents <- integer(-1200..1200),
              max_runs: 200
            ) do
        base = SynthEngine.midi_to_frequency(note)
        tuned = SynthEngine.apply_cents(base, cents)

        cond do
          cents > 0 -> assert tuned > base
          cents < 0 -> assert tuned < base
          true -> assert_in_delta tuned, base, 0.0001
        end
      end
    end

    property "pitch bend never produces negative or non-finite frequencies" do
      check all(
              note <- integer(0..127),
              bend <- float(min: -1.0, max: 1.0),
              range <- integer(1..24),
              max_runs: 200
            ) do
        base = SynthEngine.midi_to_frequency(note)
        bent = SynthEngine.apply_pitch_bend(base, bend, range)

        assert bent > 0
        assert bent == bent // 1 * 1.0 or is_float(bent)
        refute bent in [:nan, :infinity, :neg_infinity]
      end
    end

    property "rendered fundamental frequency tracks bent/tuned target across random inputs" do
      check all(
              note <- integer(24..96),
              cents <- integer(-200..200),
              bend <- float(min: -1.0, max: 1.0),
              sample_rate <- member_of(@sample_rates),
              max_runs: 40
            ) do
        base = SynthEngine.midi_to_frequency(note)
        cents_applied = apply_cents_math(base, cents)
        expected = apply_bend_math(cents_applied, bend, 2)

        samples =
          render_samples(note,
            cents: cents,
            pitch_bend: bend,
            pitch_bend_range: 2,
            sample_rate: sample_rate,
            duration_ms: 150
          )

        measured = measure_frequency_by_zero_crossings(samples, sample_rate)

        # Wider tolerance here since zero-crossing detection has more
        # quantization error at low sample rates / low frequencies.
        assert_in_delta measured, expected, max(expected * 0.05, 1.0)
      end
    end
  end

  # ---------------------------------------------------------------------
  # 7. Edge cases from real hardware controllers
  # ---------------------------------------------------------------------

  describe "hardware edge cases" do
    test "lowest MIDI note (0) renders without error and produces a sub-audible-but-valid frequency" do
      freq = SynthEngine.midi_to_frequency(0)
      assert freq > 0
      assert_in_delta freq, 8.1758, 0.01
    end

    test "highest MIDI note (127) renders without error and produces a high but valid frequency" do
      freq = SynthEngine.midi_to_frequency(127)
      assert_in_delta freq, 12543.85, 0.5
    end

    test "extreme negative cents (-2400, two octaves down) computed correctly" do
      base = SynthEngine.midi_to_frequency(72)
      tuned = SynthEngine.apply_cents(base, -2400)

      assert_in_delta tuned, base / 4, base / 4 * 0.001
    end

    test "extreme positive cents (+2400, two octaves up) computed correctly" do
      base = SynthEngine.midi_to_frequency(48)
      tuned = SynthEngine.apply_cents(base, 2400)

      assert_in_delta tuned, base * 4, base * 4 * 0.001
    end

    test "maximum hardware pitch-bend range (24 semitones, two octaves) computed correctly" do
      base = SynthEngine.midi_to_frequency(60)

      full_up = SynthEngine.apply_pitch_bend(base, 1.0, 24)
      full_down = SynthEngine.apply_pitch_bend(base, -1.0, 24)

      assert_in_delta full_up, base * 4, base * 4 * 0.001
      assert_in_delta full_down, base / 4, base / 4 * 0.001
    end

    test "velocity does not shift pitch, only amplitude" do
      expected = SynthEngine.midi_to_frequency(64)

      for velocity <- [1, 32, 64, 100, 127] do
        samples = render_samples(64, velocity: velocity, duration_ms: 150)
        measured = measure_frequency_by_zero_crossings(samples, 44_100)

        assert_in_delta measured, expected, expected * 0.02,
          "velocity=#{velocity} unexpectedly shifted pitch"
      end
    end
  end
end
