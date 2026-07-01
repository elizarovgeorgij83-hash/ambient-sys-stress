defmodule StressSynth.OsMonitor.MacOS do
  @moduledoc """
  Gathers Apple Silicon thermal / power diagnostics on macOS by shelling out
  to system tools (`pmset`, `powermetrics`, `sysctl`, `ioreg`).

  Most detailed thermal data (die temperature, throttling state, per-cluster
  power) is only exposed via `powermetrics`, which requires root privileges.
  When `powermetrics` is unavailable (no sudo / not macOS), this module falls
  back to whatever coarse-grained signals it can obtain from unprivileged
  tools such as `pmset -g therm` and `sysctl`.
  """

  require Logger

  @type thermal_level :: :nominal | :fair | :serious | :critical | :unknown

  @type thermal_report :: %{
          platform: :macos,
          collected_at: DateTime.t(),
          cpu_speed_limit_percent: non_neg_integer() | nil,
          thermal_level: thermal_level(),
          thermal_pressure_raw: String.t() | nil,
          cpu_die_temperature_c: float() | nil,
          gpu_die_temperature_c: float() | nil,
          package_power_watts: float() | nil,
          cpu_power_watts: float() | nil,
          gpu_power_watts: float() | nil,
          throttled: boolean(),
          source: :powermetrics | :pmset | :unavailable,
          errors: [String.t()]
        }

  @powermetrics_path "/usr/bin/powermetrics"
  @pmset_path "/usr/bin/pmset"
  @sysctl_path "/usr/sbin/sysctl"

  # Default sample duration for powermetrics, in milliseconds.
  @default_sample_ms 1_000

  @doc """
  Collects a full thermal report, preferring `powermetrics` when it is
  available and runnable (i.e. the process has sufficient privileges),
  falling back to `pmset -g therm` otherwise.

  Options:

    * `:sample_ms` - how long to sample powermetrics for (default #{@default_sample_ms})
    * `:timeout_ms` - hard timeout for the external command (default sample_ms + 5000)
  """
  @spec collect(keyword()) :: thermal_report()
  def collect(opts \\ []) do
    base = %{
      platform: :macos,
      collected_at: DateTime.utc_now(),
      cpu_speed_limit_percent: nil,
      thermal_level: :unknown,
      thermal_pressure_raw: nil,
      cpu_die_temperature_c: nil,
      gpu_die_temperature_c: nil,
      package_power_watts: nil,
      cpu_power_watts: nil,
      gpu_power_watts: nil,
      throttled: false,
      source: :unavailable,
      errors: []
    }

    cond do
      not macos?() ->
        %{base | errors: ["not running on macOS" | base.errors]}

      powermetrics_available?() ->
        collect_via_powermetrics(base, opts)

      true ->
        collect_via_pmset(base)
    end
  end

  @doc """
  Returns `true` if the current OS is macOS (Darwin kernel).
  """
  @spec macos?() :: boolean()
  def macos?() do
    case :os.type() do
      {:unix, :darwin} -> true
      _ -> false
    end
  end

  @doc """
  Checks whether the `powermetrics` binary exists and appears runnable
  (this does not guarantee sufficient privileges at call time, since sudo
  password prompts can still fail silently in non-interactive contexts).
  """
  @spec powermetrics_available?() :: boolean()
  def powermetrics_available?() do
    File.exists?(@powermetrics_path)
  end

  # ---------------------------------------------------------------------
  # powermetrics-based collection
  # ---------------------------------------------------------------------

  defp collect_via_powermetrics(base, opts) do
    sample_ms = Keyword.get(opts, :sample_ms, @default_sample_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, sample_ms + 5_000)

    args = [
      "--samplers",
      "smc,cpu_power,gpu_power,thermal",
      "-i",
      Integer.to_string(sample_ms),
      "-n",
      "1"
    ]

    case run_command(@powermetrics_path, args, timeout_ms) do
      {:ok, output} ->
        parse_powermetrics_output(output, base)

      {:error, reason} ->
        Logger.warning(
          "powermetrics unavailable or failed (#{inspect(reason)}); falling back to pmset"
        )

        collect_via_pmset(%{base | errors: [reason | base.errors]})
    end
  end

  # Parses the plaintext output of `powermetrics` for the fields we care
  # about. The format is stable across recent macOS versions but is not a
  # formal/versioned API, so parsing is defensive and tolerant of missing
  # sections.
  defp parse_powermetrics_output(output, base) do
    cpu_die_temp = extract_float(output, ~r/CPU die temperature:\s*([\d.]+)\s*C/)
    gpu_die_temp = extract_float(output, ~r/GPU die temperature:\s*([\d.]+)\s*C/)
    pkg_power = extract_float(output, ~r/Combined Power \(CPU \+ GPU \+ ANE\):\s*([\d.]+)\s*mW/)
    cpu_power = extract_float(output, ~r/CPU Power:\s*([\d.]+)\s*mW/)
    gpu_power = extract_float(output, ~r/GPU Power:\s*([\d.]+)\s*mW/)

    thermal_level_raw =
      Regex.run(~r/Current pressure level:\s*(\w+)/, output, capture: :all_but_first)

    thermal_level = normalize_thermal_level(thermal_level_raw)

    throttled? =
      Regex.match?(~r/CPU Thermal Level:\s*[1-9]/, output) or
        thermal_level in [:serious, :critical]

    %{
      base
      | source: :powermetrics,
        cpu_die_temperature_c: cpu_die_temp,
        gpu_die_temperature_c: gpu_die_temp,
        package_power_watts: mw_to_w(pkg_power),
        cpu_power_watts: mw_to_w(cpu_power),
        gpu_power_watts: mw_to_w(gpu_power),
        thermal_level: thermal_level,
        thermal_pressure_raw: raw_or_nil(thermal_level_raw),
        throttled: throttled?
    }
  end

  defp extract_float(text, regex) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value] ->
        case Float.parse(value) do
          {float, _rest} -> float
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp mw_to_w(nil), do: nil
  defp mw_to_w(mw), do: Float.round(mw / 1000.0, 3)

  defp raw_or_nil([value]), do: value
  defp raw_or_nil(_), do: nil

  # ---------------------------------------------------------------------
  # pmset-based fallback (unprivileged)
  # ---------------------------------------------------------------------

  defp collect_via_pmset(base) do
    case run_command(@pmset_path, ["-g", "therm"], 5_000) do
      {:ok, output} ->
        parse_pmset_therm(output, base)

      {:error, reason} ->
        collect_via_sysctl(%{base | errors: [reason | base.errors]})
    end
  end

  # Example pmset -g therm output:
  #
  #   Currently no thermal warning level has been set
  #   CPU_Speed_Limit         = 100
  #
  # or when throttled:
  #
  #   CPU_Scheduler_Limit     = 45
  #   CPU_Available_CPUs      = 6
  #   CPU_Speed_Limit         = 45
  defp parse_pmset_therm(output, base) do
    speed_limit =
      case Regex.run(~r/CPU_Speed_Limit\s*=\s*(\d+)/, output, capture: :all_but_first) do
        [value] -> String.to_integer(value)
        _ -> nil
      end

    thermal_level =
      case speed_limit do
        nil -> :unknown
        100 -> :nominal
        limit when limit >= 80 -> :fair
        limit when limit >= 50 -> :serious
        _ -> :critical
      end

    %{
      base
      | source: :pmset,
        cpu_speed_limit_percent: speed_limit,
        thermal_level: thermal_level,
        thermal_pressure_raw: String.trim(output),
        throttled: not is_nil(speed_limit) and speed_limit < 100
    }
  end

  # ---------------------------------------------------------------------
  # sysctl-based last-resort fallback (very limited signal)
  # ---------------------------------------------------------------------

  defp collect_via_sysctl(base) do
    case run_command(@sysctl_path, ["-n", "machdep.xcpm.cpu_thermal_level"], 3_000) do
      {:ok, output} ->
        case Integer.parse(String.trim(output)) do
          {level, _} ->
            %{
              base
              | source: :pmset,
                thermal_level: sysctl_level_to_thermal(level),
                thermal_pressure_raw: "machdep.xcpm.cpu_thermal_level=#{level}",
                throttled: level > 0
            }

          :error ->
            %{base | errors: ["failed to parse sysctl output: #{output}" | base.errors]}
        end

      {:error, reason} ->
        %{base | errors: [reason | base.errors]}
    end
  end

  defp sysctl_level_to_thermal(0), do: :nominal
  defp sysctl_level_to_thermal(level) when level in 1..2, do: :fair
  defp sysctl_level_to_thermal(level) when level in 3..4, do: :serious
  defp sysctl_level_to_thermal(_), do: :critical

  defp normalize_thermal_level([raw]) do
    case String.downcase(raw) do
      "nominal" -> :nominal
      "fair" -> :fair
      "serious" -> :serious
      "critical" -> :critical
      _ -> :unknown
    end
  end

  defp normalize_thermal_level(_), do: :unknown

  # ---------------------------------------------------------------------
  # Low-level command execution helper
  # ---------------------------------------------------------------------

  # Runs an external command with a hard timeout, returning either the
  # captured stdout or an error tuple describing why it failed. This wraps
  # `System.cmd/3` inside a supervised task so that hung/slow diagnostic
  # tools (which can happen with powermetrics under sudo prompts) cannot
  # block the caller indefinitely.
  @spec run_command(String.t(), [String.t()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp run_command(executable, args, timeout_ms) do
    if not File.exists?(executable) do
      {:error, "executable not found: #{executable}"}
    else
      task =
        Task.async(fn ->
          try do
            System.cmd(executable, args, stderr_to_stdout: true)
          rescue
            e -> {:exception, Exception.message(e)}
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:exception, msg}} ->
          {:error, "exception running #{executable}: #{msg}"}

        {:ok, {output, 0}} ->
          {:ok, output}

        {:ok, {output, exit_code}} ->
          {:error, "#{executable} exited with #{exit_code}: #{String.slice(output, 0, 200)}"}

        nil ->
          {:error, "#{executable} timed out after #{timeout_ms}ms"}
      end
    end
  end
end
