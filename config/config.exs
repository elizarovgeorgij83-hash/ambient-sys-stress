import Config

# ---------------------------------------------------------------------------
# General application configuration
# ---------------------------------------------------------------------------
config :app,
  ecto_repos: [App.Repo],
  generators: [timestamp_type: :utc_datetime]

# ---------------------------------------------------------------------------
# Endpoint configuration
#
# Port allocations are centralized here so that every environment (dev,
# test, prod) can be reasoned about from a single place. Ports can still be
# overridden via environment variables in runtime.exs for deployments that
# need dynamic port assignment (e.g. behind a load balancer).
# ---------------------------------------------------------------------------
config :app, AppWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: AppWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: App.PubSub,
  live_view: [signing_salt: "Qs3Kd9Lp"]

# ---------------------------------------------------------------------------
# Port allocations
#
# Each service that the umbrella app exposes gets a dedicated, well-known
# port. Keeping them in one map avoids collisions and makes it trivial to
# see the full picture of what listens where.
# ---------------------------------------------------------------------------
config :app, :ports,
  http: 4000,           # main HTTP/JSON API
  https: 4443,          # TLS-terminated HTTP API
  websocket: 4001,      # real-time signalling / control channel
  rtp_audio: 5004,      # RTP audio stream ingress (even port per RFC 3550)
  rtcp_audio: 5005,      # RTCP companion channel (rtp_audio + 1)
  metrics: 9568         # Prometheus scrape endpoint

# ---------------------------------------------------------------------------
# Audio sampling configuration
#
# Centralizing sample rates avoids magic numbers scattered across the audio
# pipeline (capture, resampling, encoding, and playback stages all need to
# agree on the same set of supported rates).
# ---------------------------------------------------------------------------
config :app, :audio,
  default_sample_rate: 48_000,       # Hz, matches most modern codecs (Opus)
  supported_sample_rates: [
    8_000,    # narrowband telephony (G.711)
    16_000,   # wideband voice
    24_000,   # Opus wideband alternative
    44_100,   # CD-quality audio (legacy compatibility)
    48_000    # standard professional / WebRTC rate
  ],
  channels: 1,                        # mono by default; stereo enabled per-stream
  bit_depth: 16,                      # PCM bit depth for internal buffers
  frame_duration_ms: 20,              # standard RTP packetization interval
  jitter_buffer_ms: 60                # default jitter buffer target latency

# ---------------------------------------------------------------------------
# Logger configuration
# ---------------------------------------------------------------------------
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# ---------------------------------------------------------------------------
# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# ---------------------------------------------------------------------------
import_config "#{config_env()}.exs"
