# Audio Mapping Engine

A lightweight, extensible library and CLI tool for mapping, routing, and transforming multi-channel audio streams. The project provides a declarative way to describe how input audio channels (e.g., from a DAW, hardware interface, or streaming source) map onto output channels/buses, along with gain, panning, and format conversion rules.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Project Structure](#project-structure)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Audio Mapping Logic](#audio-mapping-logic)
  - [Mapping File Format](#mapping-file-format)
  - [Channel Resolution Order](#channel-resolution-order)
  - [Gain & Pan Calculations](#gain--pan-calculations)
  - [Sample Rate & Bit Depth Handling](#sample-rate--bit-depth-handling)
- [Configuration](#configuration)
- [CLI Usage](#cli-usage)
- [Library Usage (Python API)](#library-usage-python-api)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

## Overview

Modern audio pipelines often need to route signals between an arbitrary number of input and output channels — for example, taking a 6-channel surround recording and downmixing it to stereo, or splitting a mono microphone feed across multiple monitor buses. This project centralizes that logic into a single, testable, and configuration-driven engine.

The core idea: **you describe the mapping once (in JSON/YAML), and the engine handles the signal routing, gain staging, and format normalization for you.**

## Features

- 🎚️ **Flexible channel mapping** — one-to-one, one-to-many, many-to-one, or fully custom matrices.
- 🔊 **Gain and pan control** per mapping rule, specified in dB or linear amplitude.
- 🔁 **Sample rate & bit depth conversion** using high-quality resampling (via `soxr` / `libsamplerate` bindings).
- 🧩 **Pluggable format support** — WAV, FLAC, and raw PCM out of the box; extensible for other codecs.
- 🧪 **Deterministic & testable** — mapping resolution is a pure function of the config, making it easy to unit test.
- 🖥️ **CLI and Python API** — use it as a standalone tool or embed it in your own application.

## Project Structure

```
.
├── README.md                  # This file
├── pyproject.toml             # Project metadata & dependencies
├── src/
│   └── audio_mapper/
│       ├── __init__.py
│       ├── cli.py             # Command-line entry point
│       ├── config.py          # Mapping configuration loader/validator
│       ├── engine.py          # Core routing/mixing engine
│       ├── resampler.py       # Sample rate & bit depth conversion
│       ├── io/
│       │   ├── __init__.py
│       │   ├── wav.py         # WAV reader/writer
│       │   └── flac.py        # FLAC reader/writer
│       └── models.py          # Data classes: Channel, Mapping, Route
├── examples/
│   ├── stereo_to_5_1.yaml     # Example: expand stereo to 5.1 surround
│   ├── surround_to_stereo.yaml# Example: downmix 5.1 to stereo
│   └── mono_broadcast.yaml    # Example: mono mic to multiple monitor buses
├── tests/
│   ├── test_config.py
│   ├── test_engine.py
│   └── fixtures/
│       └── sample_inputs/
└── docs/
    └── mapping_spec.md        # Full formal spec of the mapping file format
```

## Requirements

- Python 3.10+
- `numpy >= 1.24`
- `soundfile >= 0.12` (libsndfile bindings for WAV/FLAC I/O)
- `soxr >= 0.3` (high-quality resampling)
- `pyyaml >= 6.0` (for YAML mapping files)

## Installation

```bash
# Clone the repository
git clone https://github.com/your-org/audio-mapping-engine.git
cd audio-mapping-engine

# Create and activate a virtual environment (recommended)
python -m venv .venv
source .venv/bin/activate   # On Windows: .venv\Scripts\activate

# Install the package in editable mode with dev dependencies
pip install -e ".[dev]"
```

Verify the installation:

```bash
audio-mapper --version
```

## Quick Start

1. Define a mapping file (`mapping.yaml`):

```yaml
# mapping.yaml
input:
  channels: 2          # Stereo input
  sample_rate: 44100
  bit_depth: 16

output:
  channels: 6           # 5.1 surround output
  sample_rate: 48000
  bit_depth: 24

routes:
  - source: 0           # Left input
    destination: 0       # Front Left
    gain_db: 0
  - source: 1           # Right input
    destination: 1       # Front Right
    gain_db: 0
  - source: 0
    destination: 4       # Rear Left (duplicated, attenuated)
    gain_db: -6
  - source: 1
    destination: 5       # Rear Right (duplicated, attenuated)
    gain_db: -6
  - source: 0
    destination: 3       # LFE (mono sum, heavily attenuated)
    gain_db: -12
    pan: 0.5             # Blend with source 1 at 50%
```

2. Run the mapper:

```bash
audio-mapper map --input input.wav --output output.wav --mapping mapping.yaml
```

3. The tool reads `input.wav`, applies the routing/gain/resampling rules described in `mapping.yaml`, and writes the result to `output.wav`.

## Audio Mapping Logic

The heart of this project is the **mapping engine**, which resolves an arbitrary set of input channels to an arbitrary set of output channels based on a declarative configuration.

### Mapping File Format

A mapping file consists of three top-level sections:

| Section    | Description                                                                 |
|------------|-------------------------------------------------------------------------------|
| `input`    | Describes expected input format: channel count, sample rate, bit depth.       |
| `output`   | Describes desired output format: channel count, sample rate, bit depth.       |
| `routes`   | A list of routing rules, each connecting one input channel to one output channel. |

Each route entry supports the following fields:

```yaml
- source: <int>        # Zero-based index of the input channel
  destination: <int>    # Zero-based index of the output channel
  gain_db: <float>      # Gain applied to this route, in decibels (default: 0)
  pan: <float>          # Optional blend factor [0.0 - 1.0] when combining
                        # multiple sources into the same destination (default: 1.0)
  invert_phase: <bool>  # Optional; flips polarity of the routed signal (default: false)
```

Multiple routes may target the same `destination` — in that case, the engine **sums** the contributions after gain/pan is applied. This allows arbitrary downmix and upmix matrices to be expressed as a flat list of routes.

### Channel Resolution Order

When the engine resolves a mapping file, it proceeds through these steps:

1. **Validation** — `config.py` validates that all `source` indices are within `input.channels` and all `destination` indices are within `output.channels`. Invalid mappings raise a `MappingConfigError` early, before any audio is processed.
2. **Grouping** — Routes are grouped by `destination` channel. Each destination channel accumulates a list of `(source, gain, pan, invert_phase)` tuples.
3. **Per-sample mixing** — For each output sample frame, the engine iterates over the destination's route list, reads the corresponding source sample, applies gain (converted from dB to linear amplitude) and phase inversion, multiplies by the pan factor, and accumulates the result.
4. **Normalization (optional)** — If the `normalize: true` flag is set at the top level of the config, the engine scans the final buffer and normalizes peak amplitude to -1 dBFS to avoid clipping introduced by summed routes.
5. **Format conversion** — Sample rate and bit depth conversion (see below) are applied last, after all routing/mixing is complete, to avoid compounding quantization error.

This ordering guarantees deterministic output: given the same input audio and mapping file, the output is bit-for-bit reproducible.

### Gain & Pan Calculations

- **Gain** is specified in decibels (`gain_db`) and converted to a linear multiplier via:

  ```
  linear_gain = 10 ** (gain_db / 20)
  ```

- **Pan** is a linear blend factor between `0.0` and `1.0`, used when multiple sources feed the same destination. A pan of `1.0` means the source contributes at full gain; `0.0` mutes it entirely (its gain is still computed but multiplied by 0). This lets you crossfade or blend inputs smoothly rather than doing a hard sum.

- **Phase inversion** flips the sign of the sample (`sample *= -1`) before summing — useful for phase-cancellation tricks or mid-side decoding.

### Sample Rate & Bit Depth Handling

- Sample rate conversion uses the `soxr` library (a high-quality, low-latency resampler) with the `HQ` (high quality) profile by default. This can be overridden via the `resample_quality` field in the config (`LQ`, `MQ`, `HQ`, `VHQ`).
- Bit depth conversion is performed via linear scaling and dithering (triangular dither, TPDF) when reducing bit depth (e.g., 24-bit → 16-bit) to minimize quantization artifacts.
- All internal processing is done in 64-bit floating point regardless of input/output bit depth, to avoid intermediate precision loss during the mixing stage.

## Configuration

Besides the mapping file, global engine behavior can be tuned via a `config.yaml` (optional, defaults shown):

```yaml
# config.yaml (optional, global engine defaults)
normalize: false            # Whether to auto-normalize output peak level
resample_quality: HQ        # One of: LQ, MQ, HQ, VHQ
dither: true                # Apply dithering on bit-depth reduction
buffer_size: 8192           # Frames processed per chunk (streaming mode)
log_level: INFO             # DEBUG, INFO, WARNING, ERROR
```

Load it explicitly with `--config config.yaml`, or place a `config.yaml` in the working directory and it will be picked up automatically.

## CLI Usage

```bash
# Basic mapping
audio-mapper map --input in.wav --output out.wav --mapping mapping.yaml

# Specify a global config file
audio-mapper map --input in.wav --output out.wav --mapping mapping.yaml --config config.yaml

# Validate a mapping file without processing audio
audio-mapper validate --mapping mapping.yaml

# Print a human-readable summary of a mapping's routing matrix
audio-mapper inspect --mapping mapping.yaml

# List supported input/output formats
audio-mapper formats
```

Run `audio-mapper --help` for the full list of commands and options.

## Library Usage (Python API)

You can also use the engine directly from Python code:

```python
from audio_mapper.config import load_mapping
from audio_mapper.engine import AudioMappingEngine
from audio_mapper.io.wav import read_wav, write_wav

# Load and validate the mapping configuration
mapping = load_mapping("mapping.yaml")

# Read the source audio
samples, sample_rate, bit_depth = read_wav("input.wav")

# Create the engine and process the audio
engine = AudioMappingEngine(mapping)
output_samples = engine.process(samples, sample_rate, bit_depth)

# Write the result
write_wav(
    "output.wav",
    output_samples,
    sample_rate=mapping.output.sample_rate,
    bit_depth=mapping.output.bit_depth,
)
```

For streaming use cases (e.g., real-time processing), use the chunked API:

```python
from audio_mapper.engine import AudioMappingEngine

engine = AudioMappingEngine(mapping, buffer_size=4096)

for input_chunk in audio_source_generator():
    output_chunk = engine.process_chunk(input_chunk)
    audio_sink.write(output_chunk)

engine.flush()  # Flush any remaining buffered samples at end-of-stream
```

## Testing

The project uses `pytest` for unit and integration tests.

```bash
# Install dev dependencies (if not already installed)
pip install -e ".[dev]"

# Run the full test suite
pytest

# Run with coverage report
pytest --cov=audio_mapper --cov-report=term-missing

# Run only the mapping-logic tests
pytest tests/test_engine.py -v
```

Test fixtures (short WAV samples and mapping configs) live under `tests/fixtures/`. When adding new routing scenarios, please add a corresponding fixture and a regression test in `tests/test_engine.py`.

## Contributing

1. Fork the repository and create a feature branch: `git checkout -b feature/my-change`.
2. Make your changes, ensuring existing tests pass and new logic is covered by tests.
3. Run `ruff check .` and `mypy src/` to ensure linting and type checks pass.
4. Submit a pull request with a clear description of the change and, if applicable, an updated section in `docs/mapping_spec.md`.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
