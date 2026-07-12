# voice-notes

A deliberately small voice-notes app for the real-time audio-input primitive. It is a native-rendered macOS sample: choose the system default or an enumerated input, start a short capture, then stop to save `voice-note.wav` in the process working directory.

```sh
native dev
```

## What it demonstrates

- **Device policy is explicit** — the selected `System default` supplies an empty device id, so it follows the OS default. Selecting a listed microphone pins its opaque id for this capture. Refresh re-enumerates devices without starting capture or prompting for access.
- **PCM has its own data plane** — `CaptureStore.sink()` receives borrowed interleaved f32 frames on the audio callback. It only copies into preallocated, app-owned memory and publishes counters; frames never become UI messages, bridge messages, JSON, or journal data.
- **Lifecycle stays compact** — `EffectAudioInput` tells the model about start, source/format/device changes, interruptions, permission refusal, and failure. A session id makes a late event from an old capture harmless.
- **Recording is an app policy** — after stop, the sample converts the bounded f32 buffer to PCM-16 WAV and writes it through `fx.writeFile`. The SDK primitive does not prescribe WAV, VAD, transcription, note storage, or a microphone UI.

## Boundaries

The sample’s output is intentionally capped by the effects channel’s 1 MiB whole-file write: approximately 10.9 seconds at 48 kHz mono or 5.4 seconds stereo. It has no silence detection, compression, transcription, mixing, echo cancellation, background recording, or playback library. Those are distinct application-level policies.

## Tests

```sh
native test -Dplatform=null
```

The suite uses a synthetic input frame through the same `AudioInputSink` contract, confirms it never becomes an effect message, verifies device selection and stale-session handling, and validates the exact WAV bytes queued for the file effect. No microphone hardware is required.
