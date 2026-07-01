defmodule StressSynthWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for the StressSynth web application.

  This module configures:
    * the HTTP server (via Cowboy adapter),
    * the static asset pipeline (compressed/cached assets, code reloading),
    * session handling,
    * and WebSocket routing for real-time audio transport (used by the
      synth engine to stream PCM/Opus frames to and from connected clients).
  """

  use Phoenix.Endpoint, otp_app: :stress_synth

  # The session will be stored in a signed cookie. It is used to keep
  # track of lightweight session data (e.g. current user, UI state) that
  # does not need to be persisted server-side.
  @session_options [
    store: :cookie,
    key: "_stress_synth_key",
    signing_salt: "sTr3ssSyn7hSalt",
    same_site: "Lax"
  ]

  # Real-time audio transport socket.
  #
  # This is the primary WebSocket entry point used by the browser-based
  # synth client to stream audio buffers to the server (for analysis /
  # stress-testing) and to receive synthesized audio frames back.
  #
  # `websocket:` options are tuned for low-latency binary audio frames:
  #   * `timeout` keeps idle connections alive long enough for sparse
  #     control messages while still reaping dead sockets,
  #   * `max_frame_size` allows sizable binary audio chunks per frame,
  #   * `compress: false` avoids adding CPU overhead / latency to already
  #     compressed or already-small audio payloads.
  socket "/socket", StressSynthWeb.AudioSocket,
    websocket: [
      timeout: 60_000,
      max_frame_size: 1_048_576,
      compress: false,
      check_origin: false
    ],
    longpoll: false

  # LiveView / LiveDashboard style socket kept separate from the audio
  # transport so that control-plane traffic (UI updates, telemetry) never
  # competes with the latency-sensitive audio stream on the same channel.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serve static files from the `priv/static` directory.
  #
  # `gzip: true` is enabled only in production builds where assets are
  # pre-compiled and pre-compressed. `cache_control_for_etags` allows
  # aggressive caching keyed off content hashes for immutable assets.
  plug Plug.Static,
    at: "/",
    from: :stress_synth,
    gzip: Mix.env() == :prod,
    only: StressSynthWeb.static_paths(),
    cache_control_for_etags: "public, max-age=31536000, immutable",
    headers: %{"cross-origin-opener-policy" => "same-origin"}

  # Code reloading and live-reload wiring — only active during development.
  # This lets front-end (JS/CSS) and template changes hot-reload without
  # a manual server restart, which is especially useful while iterating
  # on the real-time audio UI.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket

    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :stress_synth
  end

  # Ensures Erlang's :telemetry events are emitted for every request,
  # allowing StressSynth.Telemetry to track request durations, audio
  # buffer sizes, and other synth-engine-related metrics.
  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Parses incoming request bodies.
  #
  # We explicitly whitelist JSON as well as raw binary bodies so that
  # audio-related HTTP fallback endpoints (used when WebSocket upgrade
  # is unavailable, e.g. behind restrictive proxies) can still accept
  # binary PCM payloads via multipart or raw octet-stream uploads.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 20_000_000

  plug Plug.MethodOverride
  plug Plug.Head

  # The session plug must come before the router so that LiveView and
  # controller-based session access works consistently across both the
  # audio transport fallback routes and the standard web routes.
  plug Plug.Session, @session_options

  plug StressSynthWeb.Router
end
