/**
 * audio_player.js
 *
 * A streaming audio player that consumes binary PCM data pushed over a
 * WebSocket connection and plays it back through the Web Audio API with
 * minimal latency and (as much as possible) gapless playback.
 *
 * The player expects raw, uncompressed PCM audio frames (16-bit signed
 * little-endian by default, but 8/16/24/32-bit int and 32-bit float are
 * supported) sent as binary WebSocket messages. Each incoming binary
 * message is decoded, converted into an AudioBuffer and scheduled for
 * playback immediately after the previously scheduled chunk, using a
 * small jitter buffer to smooth out network irregularities.
 *
 * Usage:
 *
 *   const player = new AudioStreamPlayer({
 *     url: 'wss://example.com/audio-stream',
 *     sampleRate: 48000,
 *     channels: 1,
 *     bitDepth: 16,
 *     encoding: 'pcm_signed', // 'pcm_signed' | 'pcm_unsigned' | 'float32'
 *   });
 *
 *   player.on('connect', () => console.log('connected'));
 *   player.on('underrun', () => console.warn('buffer underrun'));
 *
 *   await player.connect();
 *   player.play();
 *
 * See README.md for the full API reference.
 */

(function (global) {
  'use strict';

  // ---------------------------------------------------------------------
  // Small internal event emitter so we don't depend on any external lib.
  // ---------------------------------------------------------------------
  class EventEmitter {
    constructor() {
      this._listeners = new Map();
    }

    on(event, handler) {
      if (!this._listeners.has(event)) {
        this._listeners.set(event, new Set());
      }
      this._listeners.get(event).add(handler);
      return this;
    }

    off(event, handler) {
      if (this._listeners.has(event)) {
        this._listeners.get(event).delete(handler);
      }
      return this;
    }

    emit(event, ...args) {
      if (this._listeners.has(event)) {
        for (const handler of Array.from(this._listeners.get(event))) {
          try {
            handler(...args);
          } catch (err) {
            // Never let a subscriber's error break the audio pipeline.
            // eslint-disable-next-line no-console
            console.error(`[AudioStreamPlayer] listener for "${event}" threw:`, err);
          }
        }
      }
      return this;
    }
  }

  // ---------------------------------------------------------------------
  // PCM decoding helpers.
  // Converts raw ArrayBuffer chunks into Float32 sample arrays suitable
  // for feeding into a Web Audio AudioBuffer (which always wants -1..1
  // 32-bit floats).
  // ---------------------------------------------------------------------
  const PCMDecoder = {
    /**
     * Decodes a raw ArrayBuffer into an array of Float32Array (one per
     * channel), de-interleaving if necessary.
     *
     * @param {ArrayBuffer} buffer      Raw binary chunk from the socket.
     * @param {Object} format
     * @param {number} format.channels  Number of interleaved channels.
     * @param {number} format.bitDepth  8 | 16 | 24 | 32.
     * @param {string} format.encoding  'pcm_signed' | 'pcm_unsigned' | 'float32'.
     * @param {boolean} [format.littleEndian=true]
     * @returns {Float32Array[]} one Float32Array per channel.
     */
    decode(buffer, format) {
      const { channels, bitDepth, encoding } = format;
      const littleEndian = format.littleEndian !== false;
      const bytesPerSample = bitDepth / 8;
      const totalSamples = Math.floor(buffer.byteLength / bytesPerSample);
      const frameCount = Math.floor(totalSamples / channels);

      if (frameCount <= 0) {
        return channels ? Array.from({ length: channels }, () => new Float32Array(0)) : [];
      }

      const view = new DataView(buffer);
      const out = Array.from({ length: channels }, () => new Float32Array(frameCount));

      const readSample = this._sampleReader(view, bitDepth, encoding, littleEndian);

      let byteOffset = 0;
      for (let frame = 0; frame < frameCount; frame++) {
        for (let ch = 0; ch < channels; ch++) {
          out[ch][frame] = readSample(byteOffset);
          byteOffset += bytesPerSample;
        }
      }

      return out;
    },

    /**
     * Returns a function(byteOffset) -> normalized float sample in [-1, 1]
     * tailored to the requested bit depth / encoding, to avoid branching
     * inside the hot per-sample loop.
     */
    _sampleReader(view, bitDepth, encoding, littleEndian) {
      if (encoding === 'float32') {
        return (offset) => view.getFloat32(offset, littleEndian);
      }

      switch (bitDepth) {
        case 8:
          if (encoding === 'pcm_unsigned') {
            return (offset) => (view.getUint8(offset) - 128) / 128;
          }
          return (offset) => view.getInt8(offset) / 128;

        case 16:
          if (encoding === 'pcm_unsigned') {
            return (offset) => (view.getUint16(offset, littleEndian) - 32768) / 32768;
          }
          return (offset) => view.getInt16(offset, littleEndian) / 32768;

        case 24: {
          // DataView has no native 24-bit accessor; assemble manually.
          const readInt24 = (offset) => {
            let b0;
            let b1;
            let b2;
            if (littleEndian) {
              b0 = view.getUint8(offset);
              b1 = view.getUint8(offset + 1);
              b2 = view.getUint8(offset + 2);
            } else {
              b2 = view.getUint8(offset);
              b1 = view.getUint8(offset + 1);
              b0 = view.getUint8(offset + 2);
            }
            let value = (b2 << 16) | (b1 << 8) | b0;
            // Sign-extend from 24 to 32 bits.
            if (value & 0x800000) {
              value |= 0xff000000;
            }
            return value;
          };
          if (encoding === 'pcm_unsigned') {
            return (offset) => (readInt24(offset) + 8388608) / 8388608 - 1;
          }
          return (offset) => readInt24(offset) / 8388608;
        }

        case 32:
          if (encoding === 'pcm_unsigned') {
            return (offset) => (view.getUint32(offset, littleEndian) - 2147483648) / 2147483648;
          }
          return (offset) => view.getInt32(offset, littleEndian) / 2147483648;

        default:
          throw new Error(`Unsupported bitDepth: ${bitDepth}`);
      }
    },
  };

  // ---------------------------------------------------------------------
  // Main player class.
  // ---------------------------------------------------------------------
  class AudioStreamPlayer extends EventEmitter {
    /**
     * @param {Object} options
     * @param {string} options.url                WebSocket URL to connect to.
     * @param {number} [options.sampleRate=48000]  Sample rate of the incoming PCM stream.
     * @param {number} [options.channels=1]        Number of channels in the incoming PCM stream.
     * @param {number} [options.bitDepth=16]        Bit depth of each PCM sample (8, 16, 24, 32).
     * @param {string} [options.encoding='pcm_signed'] 'pcm_signed' | 'pcm_unsigned' | 'float32'.
     * @param {boolean} [options.littleEndian=true] Byte order of the incoming PCM stream.
     * @param {number} [options.jitterBufferSeconds=0.15] How much audio to
     *        buffer before starting playback, to absorb network jitter.
     * @param {number} [options.maxQueuedSeconds=5] Safety cap: if more than
     *        this much audio is queued (e.g. because the tab was backgrounded)
     *        older chunks are dropped to avoid unbounded memory growth and
     *        runaway latency.
     * @param {AudioContext} [options.audioContext] Reuse an existing AudioContext
     *        instead of creating a new one.
     * @param {boolean} [options.autoReconnect=true]
     * @param {number} [options.reconnectDelayMs=1000]
     * @param {number} [options.maxReconnectDelayMs=15000]
     */
    constructor(options) {
      super();

      if (!options || !options.url) {
        throw new Error('AudioStreamPlayer requires an options.url pointing to a WebSocket endpoint.');
      }

      this.url = options.url;
      this.format = {
        channels: options.channels || 1,
        bitDepth: options.bitDepth || 16,
        encoding: options.encoding || 'pcm_signed',
        littleEndian: options.littleEndian !== false,
      };
      this.sampleRate = options.sampleRate || 48000;

      this.jitterBufferSeconds = options.jitterBufferSeconds != null ? options.jitterBufferSeconds : 0.15;
      this.maxQueuedSeconds = options.maxQueuedSeconds != null ? options.maxQueuedSeconds : 5;

      this.autoReconnect = options.autoReconnect !== false;
      this.reconnectDelayMs = options.reconnectDelayMs || 1000;
      this.maxReconnectDelayMs = options.maxReconnectDelayMs || 15000;
      this._currentReconnectDelay = this.reconnectDelayMs;

      // Web Audio graph: source(s) -> gain -> destination.
      const AC = global.AudioContext || global.webkitAudioContext;
      if (!AC) {
        throw new Error('Web Audio API is not supported in this environment.');
      }
      this.audioContext = options.audioContext || new AC();
      this.gainNode = this.audioContext.createGain();
      this.gainNode.connect(this.audioContext.destination);

      this._ws = null;
      this._sockedState = 'closed'; // 'closed' | 'connecting' | 'open'
      this._nextStartTime = 0; // AudioContext time at which the next chunk should start.
      this._queuedSeconds = 0; // Amount of audio currently scheduled but not yet played.
      this._activeSources = new Set();
      this._playing = false;
      this._muted = false;
      this._destroyed = false;
      this._reconnectTimer = null;
      this._bufferingStartedAt = null;
      this._hasStartedPlaybackClock = false;

      // Total counters, useful for diagnostics / UI meters.
      this.stats = {
        bytesReceived: 0,
        chunksReceived: 0,
        chunksScheduled: 0,
        underruns: 0,
      };
    }

    // ---------------------------------------------------------------
    // Connection lifecycle
    // ---------------------------------------------------------------

    /**
     * Opens the WebSocket connection and starts listening for binary
     * audio frames. Resolves once the socket is open (does not wait for
     * the first chunk of audio).
     */
    connect() {
      if (this._destroyed) {
        return Promise.reject(new Error('AudioStreamPlayer has been destroyed.'));
      }
      if (this._ws && this._sockedState !== 'closed') {
        return Promise.resolve();
      }

      this._sockedState = 'connecting';

      return new Promise((resolve, reject) => {
        let ws;
        try {
          ws = new WebSocket(this.url);
        } catch (err) {
          this._sockedState = 'closed';
          this.emit('error', err);
          reject(err);
          return;
        }

        ws.binaryType = 'arraybuffer';
        this._ws = ws;

        ws.onopen = () => {
          this._sockedState = 'open';
          this._currentReconnectDelay = this.reconnectDelayMs; // reset backoff
          this._resetPlaybackClock();
          this.emit('connect');
          resolve();
        };

        ws.onmessage = (event) => {
          this._handleMessage(event);
        };

        ws.onerror = (event) => {
          this.emit('error', event);
        };

        ws.onclose = (event) => {
          this._sockedState = 'closed';
          this.emit('disconnect', event);
          this._ws = null;
          if (this.autoReconnect && !this._destroyed) {
            this._scheduleReconnect();
          }
        };
      });
    }

    /**
     * Closes the WebSocket without destroying the AudioContext, so the
     * player can be reconnected later via connect().
     */
    disconnect() {
      this.autoReconnect = false;
      if (this._reconnectTimer) {
        clearTimeout(this._reconnectTimer);
        this._reconnectTimer = null;
      }
      if (this._ws) {
        try {
          this._ws.close();
        } catch (err) {
          // ignore
        }
        this._ws = null;
      }
      this._sockedState = 'closed';
    }

    _scheduleReconnect() {
      if (this._reconnectTimer) return;
      this._reconnectTimer = setTimeout(() => {
        this._reconnectTimer = null;
        this.connect().catch(() => {
          // connect() already emits 'error'; backoff handled below.
        });
      }, this._currentReconnectDelay);

      this._currentReconnectDelay = Math.min(
        this._currentReconnectDelay * 2,
        this.maxReconnectDelayMs
      );
    }

    /**
     * Fully tears down the player: closes the socket, stops all
     * scheduled audio and releases the AudioContext (if we created it).
     */
    destroy() {
      this._destroyed = true;
      this.disconnect();
      this.stop();
      try {
        this.gainNode.disconnect();
      } catch (err) {
        // ignore
      }
      if (this._ownsAudioContext !== false && this.audioContext && this.audioContext.state !== 'closed') {
        this.audioContext.close().catch(() => {});
      }
    }

    // ---------------------------------------------------------------
    // Playback controls
    // ---------------------------------------------------------------

    /** Resumes the AudioContext (required after user gesture in most browsers). */
    async play() {
      if (this.audioContext.state === 'suspended') {
        await this.audioContext.resume();
      }
      this._playing = true;
      this.emit('play');
    }

    /** Suspends audio output without dropping the WebSocket connection. */
    async pause() {
      this._playing = false;
      if (this.audioContext.state === 'running') {
        await this.audioContext.suspend();
      }
      this.emit('pause');
    }

    /** Stops all currently scheduled audio and resets the playback clock. */
    stop() {
      for (const src of this._activeSources) {
        try {
          src.stop();
        } catch (err) {
          // may already have stopped naturally
        }
      }
      this._activeSources.clear();
      this._queuedSeconds = 0;
      this._hasStartedPlaybackClock = false;
      this._playing = false;
      this.emit('stop');
    }

    /** Sets output volume, 0.0 - 1.0 (or higher to amplify, use with care). */
    setVolume(value) {
      const clamped = Math.max(0, value);
      this.gainNode.gain.setTargetAtTime(clamped, this.audioContext.currentTime, 0.01);
    }

    mute() {
      this._muted = true;
      this._previousGain = this.gainNode.gain.value;
      this.gainNode.gain.setTargetAtTime(0, this.audioContext.currentTime, 0.01);
    }

    unmute() {
      if (!this._muted) return;
      this._muted = false;
      this.gainNode.gain.setTargetAtTime(
        this._previousGain != null ? this._previousGain : 1,
        this.audioContext.currentTime,
        0.01
      );
    }

    /** Amount of audio (in seconds) currently buffered ahead of playback. */
    get bufferedSeconds() {
      return Math.max(0, this._nextStartTime - this.audioContext.currentTime);
    }

    // ---------------------------------------------------------------
    // Internal: message handling / decoding / scheduling
    // ---------------------------------------------------------------

    _resetPlaybackClock() {
      this._nextStartTime = this.audioContext.currentTime + this.jitterBufferSeconds;
      this._hasStartedPlaybackClock = false;
      this._bufferingStartedAt = this.audioContext.currentTime;
    }

    _handleMessage(event) {
      // Ignore any non-binary (e.g. JSON control/status) messages; those
      // are left for higher-level application code to handle by
      // re-emitting them so consumers can still react if desired.
      if (typeof event.data === 'string') {
        this.emit('text-message', event.data);
        return;
      }

      const buffer = event.data instanceof ArrayBuffer ? event.data : null;
      if (!buffer) {
        return;
      }

      this.stats.bytesReceived += buffer.byteLength;
      this.stats.chunksReceived += 1;

      try {
        this._scheduleChunk(buffer);
      } catch (err) {
        this.emit('error', err);
      }
    }

    _scheduleChunk(rawBuffer) {
      const channelData = PCMDecoder.decode(rawBuffer, this.format);
      const frameCount = channelData.length ? channelData[0].length : 0;
      if (frameCount === 0) return;

      const audioBuffer = this.audioContext.createBuffer(
        this.format.channels,
        frameCount,
        this.sampleRate
      );

      for (let ch = 0; ch < this.format.channels; ch++) {
        audioBuffer.copyToChannel(channelData[ch], ch);
      }

      const durationSeconds = frameCount / this.sampleRate;

      // Guard against unbounded buffering (e.g. tab backgrounded, or the
      // consumer never called play()). Drop the oldest scheduling point
      // by fast-forwarding the clock instead of letting latency grow
      // forever.
      if (this._queuedSeconds > this.maxQueuedSeconds) {
        this.emit('overflow', { queuedSeconds: this._queuedSeconds });
        this._nextStartTime = this.audioContext.currentTime + this.jitterBufferSeconds;
        this._queuedSeconds = 0;
      }

      const now = this.audioContext.currentTime;
      if (this._nextStartTime < now) {
        // We fell behind (buffer underrun) — resync with fresh jitter buffer.
        if (this._hasStartedPlaybackClock) {
          this.stats.underruns += 1;
          this.emit('underrun');
        }
        this._nextStartTime = now + this.jitterBufferSeconds;
      }

      const source = this.audioContext.createBufferSource();
      source.buffer = audioBuffer;
      source.connect(this.gainNode);

      const startAt = this._nextStartTime;
      source.start(startAt);

      this._activeSources.add(source);
      source.onended = () => {
        this._activeSources.delete(source);
        this._queuedSeconds = Math.max(0, this._queuedSeconds - durationSeconds);
      };

      this._nextStartTime += durationSeconds;
      this._queuedSeconds += durationSeconds;
      this._hasStartedPlaybackClock = true;
      this.stats.chunksScheduled += 1;

      this.emit('chunk', { durationSeconds, frameCount });
    }
  }

  // Expose the class both as a CommonJS export (bundlers/tests) and as a
  // global for direct <script> usage in the browser.
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = AudioStreamPlayer;
  } else {
    global.AudioStreamPlayer = AudioStreamPlayer;
  }
})(typeof window !== 'undefined' ? window : globalThis);
