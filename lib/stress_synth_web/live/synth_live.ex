defmodule StressSynthWeb.SynthLive do
  @moduledoc """
  Phoenix LiveView module implementing an interactive synthesizer UI.

  Responsibilities:
    * Handle dynamic user interactions (play/stop, frequency, waveform type,
      volume, detune) via `phx-click`/`phx-change` events.
    * Maintain synth state on the server (source of truth for UI rendering).
    * Continuously push updated SVG waveform data to the client so the
      visual wave stays synchronized with whatever the Web Audio API is
      playing on the front-end (driven by a JS hook + a periodic tick).
    * Use `Phoenix.LiveView.JS` and hooks (assigns pushed via `push_event/3`)
      to keep the audio engine (client-side, e.g. via AudioContext) and the
      SVG rendering (server-side, computed here) in sync.
  """

  use StressSynthWeb, :live_view

  # How often (ms) we tick the animation/audio-sync clock.
  @tick_interval 40

  # SVG canvas dimensions used for wave rendering.
  @svg_width 800
  @svg_height 200

  # Supported waveform types and their generator functions.
  @waveforms ~w(sine square sawtooth triangle noise)

  # ---------------------------------------------------------------------
  # Mount / initial state
  # ---------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    # Only start the periodic tick timer once the socket is actually
    # connected (i.e. not during the static render pass), to avoid
    # spawning timers for disconnected mounts.
    if connected?(socket) do
      :timer.send_interval(@tick_interval, self(), :tick)
    end

    socket =
      socket
      |> assign(:playing, false)
      |> assign(:waveform, "sine")
      |> assign(:frequency, 440.0)
      |> assign(:volume, 0.5)
      |> assign(:detune, 0.0)
      |> assign(:phase, 0.0)
      |> assign(:elapsed_ms, 0)
      |> assign(:waveforms, @waveforms)
      |> assign(:svg_width, @svg_width)
      |> assign(:svg_height, @svg_height)
      |> assign(:page_title, "Stress Synth")

    {:ok, assign(socket, :wave_path, compute_wave_path(socket.assigns))}
  end

  # ---------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="synth-container" id="synth-root" phx-hook="SynthAudio" data-playing={to_string(@playing)}>
      <h1 class="synth-title">Stress Synth</h1>

      <div class="synth-visual">
        <svg
          viewBox={"0 0 #{@svg_width} #{@svg_height}"}
          width="100%"
          height={@svg_height}
          class="synth-wave-svg"
          preserveAspectRatio="none"
        >
          <rect width="100%" height="100%" fill="#0f0f14" />
          <path
            d={@wave_path}
            fill="none"
            stroke={wave_color(@waveform)}
            stroke-width="2"
            stroke-linecap="round"
          />
          <line x1="0" y1={@svg_height / 2} x2={@svg_width} y2={@svg_height / 2} stroke="#333" stroke-width="1" />
        </svg>
      </div>

      <div class="synth-controls">
        <button
          type="button"
          phx-click="toggle_play"
          class={"btn #{if @playing, do: "btn-stop", else: "btn-play"}"}
        >
          <%= if @playing, do: "Stop", else: "Play" %>
        </button>

        <form phx-change="update_params">
          <label>
            Waveform
            <select name="waveform">
              <%= for wf <- @waveforms do %>
                <option value={wf} selected={wf == @waveform}><%= String.capitalize(wf) %></option>
              <% end %>
            </select>
          </label>

          <label>
            Frequency (<%= Float.round(@frequency, 1) %> Hz)
            <input
              type="range"
              name="frequency"
              min="20"
              max="2000"
              step="1"
              value={@frequency}
            />
          </label>

          <label>
            Detune (<%= Float.round(@detune, 1) %> cents)
            <input
              type="range"
              name="detune"
              min="-100"
              max="100"
              step="1"
              value={@detune}
            />
          </label>

          <label>
            Volume (<%= Float.round(@volume * 100, 0) %>%)
            <input
              type="range"
              name="volume"
              min="0"
              max="1"
              step="0.01"
              value={@volume}
            />
          </label>
        </form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------
  # Event handlers
  # ---------------------------------------------------------------------

  @impl true
  def handle_event("toggle_play", _params, socket) do
    playing = !socket.assigns.playing

    socket =
      socket
      |> assign(:playing, playing)
      |> push_audio_event(playing)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_params", params, socket) do
    waveform = Map.get(params, "waveform", socket.assigns.waveform)
    frequency = parse_float(Map.get(params, "frequency"), socket.assigns.frequency)
    detune = parse_float(Map.get(params, "detune"), socket.assigns.detune)
    volume = parse_float(Map.get(params, "volume"), socket.assigns.volume)

    socket =
      socket
      |> assign(:waveform, waveform)
      |> assign(:frequency, frequency)
      |> assign(:detune, detune)
      |> assign(:volume, volume)

    socket = assign(socket, :wave_path, compute_wave_path(socket.assigns))

    socket =
      push_event(socket, "synth:update", %{
        waveform: waveform,
        frequency: frequency,
        detune: detune,
        volume: volume
      })

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------
  # Info handlers -- periodic tick to advance phase & keep SVG synced.
  # ---------------------------------------------------------------------

  @impl true
  def handle_info(:tick, socket) do
    socket =
      if socket.assigns.playing do
        elapsed = socket.assigns.elapsed_ms + @tick_interval

        # Advance phase based on frequency so the SVG wave scrolls in sync
        # with the audio being generated client-side by the Web Audio API.
        phase_increment =
          socket.assigns.frequency * @tick_interval / 1000.0 * 2.0 * :math.pi()

        new_phase =
          :math.fmod(socket.assigns.phase + phase_increment, 2.0 * :math.pi())

        socket
        |> assign(:elapsed_ms, elapsed)
        |> assign(:phase, new_phase)
        |> then(fn s -> assign(s, :wave_path, compute_wave_path(s.assigns)) end)
      else
        socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------

  # Push a client-side event instructing the SynthAudio JS hook to start
  # or stop the Web Audio API oscillator, keeping current synth params.
  defp push_audio_event(socket, true) do
    push_event(socket, "synth:play", %{
      waveform: socket.assigns.waveform,
      frequency: socket.assigns.frequency,
      detune: socket.assigns.detune,
      volume: socket.assigns.volume
    })
  end

  defp push_audio_event(socket, false) do
    push_event(socket, "synth:stop", %{})
  end

  # Parses a numeric string param into a float, falling back to `default`
  # if parsing fails or the param is missing/blank.
  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> default
    end
  end

  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value * 1.0

  # Computes an SVG path `d` attribute string representing one full-width
  # rendering of the current waveform, offset by the running phase so the
  # visual wave appears to scroll continuously in sync with audio playback.
  defp compute_wave_path(assigns) do
    %{
      waveform: waveform,
      frequency: _frequency,
      volume: volume,
      phase: phase,
      playing: playing
    } = assigns

    amplitude = if playing, do: volume, else: 0.05

    samples = 200
    mid_y = @svg_height / 2
    max_amp = mid_y * 0.9 * amplitude

    points =
      for i <- 0..samples do
        x = i / samples * @svg_width
        # theta cycles fully across the canvas width, offset by phase for
        # continuous scrolling motion synced to the tick-driven phase.
        theta = i / samples * 2.0 * :math.pi() * 4.0 + phase
        y = mid_y - max_amp * waveform_sample(waveform, theta)
        {x, y}
      end

    points_to_path(points)
  end

  # Converts a list of {x, y} points into an SVG path `d` string using a
  # simple "M x y L x y L x y ..." polyline command sequence.
  defp points_to_path([{x0, y0} | rest]) do
    initial = "M #{fmt(x0)} #{fmt(y0)}"

    rest
    |> Enum.reduce(initial, fn {x, y}, acc ->
      acc <> " L #{fmt(x)} #{fmt(y)}"
    end)
  end

  defp points_to_path([]), do: ""

  defp fmt(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 2)
  defp fmt(num) when is_integer(num), do: Integer.to_string(num)

  # Waveform generator functions, each returning a value in [-1, 1] for a
  # given phase angle `theta` (radians).
  defp waveform_sample("sine", theta), do: :math.sin(theta)

  defp waveform_sample("square", theta) do
    if :math.sin(theta) >= 0, do: 1.0, else: -1.0
  end

  defp waveform_sample("sawtooth", theta) do
    # Normalize theta to [0, 2*pi) then map linearly to [-1, 1].
    t = :math.fmod(theta, 2.0 * :math.pi())
    t = if t < 0, do: t + 2.0 * :math.pi(), else: t
    t / :math.pi() - 1.0
  end

  defp waveform_sample("triangle", theta) do
    t = :math.fmod(theta, 2.0 * :math.pi())
    t = if t < 0, do: t + 2.0 * :math.pi(), else: t
    # Triangle wave via absolute-value transform of a normalized sawtooth.
    2.0 * :math.abs(2.0 * (t / (2.0 * :math.pi()) - :math.floor(t / (2.0 * :math.pi()) + 0.5))) - 1.0
  end

  defp waveform_sample("noise", _theta) do
    # Pseudo-random noise sample in [-1, 1]; not phase-locked since noise
    # has no meaningful periodic waveform shape.
    :rand.uniform() * 2.0 - 1.0
  end

  defp waveform_sample(_unknown, theta), do: :math.sin(theta)

  # Returns a distinct stroke color per waveform type for visual clarity.
  defp wave_color("sine"), do: "#4fd1c5"
  defp wave_color("square"), do: "#f6ad55"
  defp wave_color("sawtooth"), do: "#f56565"
  defp wave_color("triangle"), do: "#68d391"
  defp wave_color("noise"), do: "#a78bfa"
  defp wave_color(_), do: "#ffffff"
end
