defmodule StressSynth.OsMonitor.Linux do
  @moduledoc """
  Linux-specific OS monitoring backend.

  Reads kernel pseudo-filesystems (`/sys`, `/proc`) directly to obtain
  precise, per-core CPU temperatures and IO scheduling / pressure delay
  statistics without shelling out to external tools.

  ## Data sources

    * Temperatures — `/sys/class/hwmon/hwmon*/temp*_input` (millidegrees C),
      correlated with per-core mapping via `/sys/class/hwmon/hwmon*/temp*_label`
      and `/sys/devices/system/cpu/cpu*/topology/core_id` when available.
    * IO scheduling delays — `/proc/pressure/io` (PSI, Linux >= 4.20) giving
      `avg10`, `avg60`, `avg300`, and `total` (microseconds) stall time.
    * Per-process IO delay — `/proc/<pid>/stat` field 42 (`delayacct_blkio_ticks`),
      converted to milliseconds using the system clock tick rate (`SC_CLK_TCK`).

  All reads are best-effort: missing files, permission errors, or absent
  kernel features return `{:error, reason}` rather than raising, so callers
  can degrade gracefully on non-Linux or restricted (e.g. containerized)
  environments.
  """

  @hwmon_root "/sys/class/hwmon"
  @cpu_root "/sys/devices/system/cpu"
  @psi_io_path "/proc/pressure/io"
  @proc_root "/proc"

  @type core_id :: non_neg_integer()
  @type millideg :: integer()

  @doc """
  Returns a map of `core_id => temperature_celsius` (float, one decimal of
  precision preserved from the millidegree kernel reading).

  Falls back to hwmon-index-based pseudo core ids (`0`, `1`, ...) when the
  kernel does not expose an explicit per-core label/topology mapping (common
  on some ARM / embedded boards), so the function always returns *something*
  useful rather than an empty map when sensors exist at all.
  """
  @spec per_core_temperatures() :: {:ok, %{core_id() => float()}} | {:error, term()}
  def per_core_temperatures do
    case list_hwmon_dirs() do
      {:ok, []} ->
        {:error, :no_hwmon_devices}

      {:ok, dirs} ->
        readings =
          dirs
          |> Enum.flat_map(&read_hwmon_temp_inputs/1)
          |> Enum.reject(&is_nil/1)

        case readings do
          [] -> {:error, :no_temperature_sensors}
          list -> {:ok, correlate_to_cores(list)}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns aggregate IO scheduling delay (pressure stall information) as
  reported by the kernel PSI subsystem.

  The result is a map with `avg10`, `avg60`, `avg300` (percentage of time,
  as floats, stalled on IO over the respective rolling windows) and
  `total_stall_us` (cumulative microseconds stalled since boot, integer).

  Requires `CONFIG_PSI=y` and the kernel cgroup v2 psi controller to be
  mounted; otherwise returns `{:error, :psi_unavailable}`.
  """
  @spec io_pressure() :: {:ok, map()} | {:error, term()}
  def io_pressure do
    case File.read(@psi_io_path) do
      {:ok, contents} -> parse_psi_io(contents)
      {:error, :enoent} -> {:error, :psi_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the per-process block IO delay for `pid`, in milliseconds, derived
  from field 42 of `/proc/<pid>/stat` (`delayacct_blkio_ticks`) scaled by the
  kernel clock tick rate (`getconf CLK_TCK`, effectively always 100 Hz on
  modern Linux but read dynamically here for correctness).
  """
  @spec process_io_delay_ms(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_io_delay_ms(pid) when is_integer(pid) and pid > 0 do
    stat_path = Path.join([@proc_root, Integer.to_string(pid), "stat"])

    with {:ok, raw} <- File.read(stat_path),
         {:ok, ticks} <- extract_blkio_ticks(raw),
         {:ok, hz} <- clock_ticks_per_second() do
      ms = div(ticks * 1000, hz)
      {:ok, ms}
    end
  end

  @doc """
  Convenience aggregate combining `per_core_temperatures/0` and
  `io_pressure/0` into a single snapshot, useful for periodic sampling by
  the stress-synth scheduler loop. Partial failures are reported per-field
  rather than failing the whole snapshot.
  """
  @spec snapshot() :: %{
          temperatures: {:ok, %{core_id() => float()}} | {:error, term()},
          io_pressure: {:ok, map()} | {:error, term()},
          sampled_at: DateTime.t()
        }
  def snapshot do
    %{
      temperatures: per_core_temperatures(),
      io_pressure: io_pressure(),
      sampled_at: DateTime.utc_now()
    }
  end

  # -- hwmon enumeration -----------------------------------------------------

  defp list_hwmon_dirs do
    case File.ls(@hwmon_root) do
      {:ok, entries} ->
        dirs =
          entries
          |> Enum.map(&Path.join(@hwmon_root, &1))
          |> Enum.filter(&File.dir?/1)

        {:ok, dirs}

      {:error, :enoent} ->
        {:error, :hwmon_not_mounted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Reads every temp*_input file in a hwmon device directory, pairing it with
  # its optional temp*_label, and the numeric sensor index parsed out of the
  # filename (e.g. "temp3_input" -> 3), used later for stable ordering.
  defp read_hwmon_temp_inputs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.match?(&1, ~r/^temp\d+_input$/))
        |> Enum.map(fn input_file ->
          idx =
            input_file
            |> String.replace_prefix("temp", "")
            |> String.replace_suffix("_input", "")
            |> String.to_integer()

          input_path = Path.join(dir, input_file)
          label_path = Path.join(dir, "temp#{idx}_label")

          with {:ok, millideg_str} <- File.read(input_path),
               {milli, _} <- Integer.parse(String.trim(millideg_str)) do
            label =
              case File.read(label_path) do
                {:ok, l} -> String.trim(l)
                _ -> nil
              end

            %{hwmon_dir: dir, index: idx, millideg: milli, label: label}
          else
            _ -> nil
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Attempts to map raw hwmon readings to logical CPU core ids.
  #
  # Strategy:
  #   1. If a label matches "Core N" (common on coretemp driver), use N.
  #   2. Otherwise fall back to a stable ordering by (hwmon_dir, index) and
  #      assign sequential pseudo core ids starting at 0.
  defp correlate_to_cores(readings) do
    {labeled, unlabeled} =
      Enum.split_with(readings, fn %{label: label} ->
        not is_nil(label) and Regex.match?(~r/^Core\s+(\d+)$/i, label)
      end)

    labeled_map =
      labeled
      |> Enum.map(fn %{label: label, millideg: milli} ->
        [_, core_str] = Regex.run(~r/^Core\s+(\d+)$/i, label)
        {String.to_integer(core_str), milli / 1000.0}
      end)
      |> Map.new()

    next_index = if map_size(labeled_map) == 0, do: 0, else: (labeled_map |> Map.keys() |> Enum.max()) + 1

    unlabeled_map =
      unlabeled
      |> Enum.sort_by(fn %{hwmon_dir: dir, index: idx} -> {dir, idx} end)
      |> Enum.with_index(next_index)
      |> Enum.map(fn {%{millideg: milli}, pseudo_id} -> {pseudo_id, milli / 1000.0} end)
      |> Map.new()

    Map.merge(labeled_map, unlabeled_map)
  end

  # -- PSI parsing ------------------------------------------------------------

  # Parses the two-line format of /proc/pressure/io:
  #
  #   some avg10=0.00 avg60=0.00 avg300=0.00 total=12345
  #   full avg10=0.00 avg60=0.00 avg300=0.00 total=6789
  #
  # We report the "full" line when present (time all tasks were stalled,
  # a truer measure of scheduling delay impact), falling back to "some".
  defp parse_psi_io(contents) do
    lines =
      contents
      |> String.split("\n", trim: true)
      |> Enum.map(&parse_psi_line/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new(fn {kind, fields} -> {kind, fields} end)

    chosen = Map.get(lines, "full") || Map.get(lines, "some")

    case chosen do
      nil ->
        {:error, :psi_parse_failed}

      fields ->
        {:ok,
         %{
           avg10: Map.get(fields, "avg10", 0.0),
           avg60: Map.get(fields, "avg60", 0.0),
           avg300: Map.get(fields, "avg300", 0.0),
           total_stall_us: Map.get(fields, "total", 0) |> trunc()
         }}
    end
  end

  defp parse_psi_line(line) do
    with [kind | rest] <- String.split(line, " ", trim: true),
         true <- kind in ["some", "full"] do
      fields =
        rest
        |> Enum.map(fn kv ->
          case String.split(kv, "=", parts: 2) do
            [k, v] -> {k, parse_number(v)}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      {kind, fields}
    else
      _ -> nil
    end
  end

  defp parse_number(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error ->
        case Integer.parse(str) do
          {i, _} -> i
          :error -> 0.0
        end
    end
  end

  # -- /proc/<pid>/stat parsing -----------------------------------------------

  # Field 42 (delayacct_blkio_ticks) of /proc/<pid>/stat. The comm field
  # (2nd whitespace-delimited field) is wrapped in parentheses and may itself
  # contain spaces/parentheses, so we split on the *last* ")" to correctly
  # locate the start of the numeric fields, per the documented proc(5) format.
  defp extract_blkio_ticks(raw) do
    case String.split(raw, ")", parts: 2) do
      [_pid_and_comm, rest] ->
        fields =
          rest
          |> String.trim_leading()
          |> String.split(" ", trim: true)

        # After splitting off "pid (comm)", `state` is fields[0], and the
        # original field numbering (1-indexed, pid=1, comm=2, state=3, ...)
        # means field 42 corresponds to index (42 - 3) = 39 in `fields`.
        case Enum.at(fields, 42 - 3) do
          nil -> {:error, :stat_field_missing}
          val -> case Integer.parse(val) do
            {ticks, _} -> {:ok, ticks}
            :error -> {:error, :stat_field_invalid}
          end
        end

      _ ->
        {:error, :stat_parse_failed}
    end
  end

  # -- clock tick rate ---------------------------------------------------------

  # Determines SC_CLK_TCK (jiffies-per-second) used to scale ticks in
  # /proc/<pid>/stat to milliseconds. Almost universally 100 on Linux, but we
  # query it dynamically via `getconf` to be robust across architectures
  # where it may differ (e.g. some embedded/alpha configs).
  defp clock_ticks_per_second do
    case System.cmd("getconf", ["CLK_TCK"], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.trim() |> Integer.parse() do
          {hz, _} when hz > 0 -> {:ok, hz}
          _ -> {:ok, 100}
        end

      _ ->
        # getconf unavailable (e.g. minimal container) — 100Hz is the
        # near-universal Linux default (CONFIG_HZ=100 equivalent for
        # userspace-visible ticks regardless of actual kernel HZ).
        {:ok, 100}
    end
  end
end
