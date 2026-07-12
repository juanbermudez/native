# voice-notes

A deliberately small voice-notes app for the real-time audio-input primitive. It is a native-rendered macOS sample: first explain why microphone access is needed, let the user ask macOS for it, then choose the system default or an enumerated input, capture a short note, and save `voice-note.wav` in the process working directory.

```sh
native dev
```

## What it demonstrates

- **Consent is an intentional first state** — the initial screen explains the request and offers `Allow microphone`. It starts a short-lived input probe, which is the real operation that makes macOS present its system prompt; after `.started`, the probe stops and the recorder appears. The app does not maintain a second, pretend permission store.
- **Device policy is explicit** — after access is confirmed, the selected `System default` supplies an empty device id, so it follows the OS default. Selecting a listed microphone pins its opaque id for this capture. Refresh re-enumerates devices without starting a recording or prompting again.
- **PCM has its own data plane** — `CaptureStore.sink()` receives borrowed interleaved f32 frames on the audio callback. It only copies into preallocated, app-owned memory and publishes counters; frames never become UI messages, bridge messages, JSON, or journal data.
- **Lifecycle stays compact** — `EffectAudioInput` tells the model about start, source/format/device changes, interruptions, permission refusal, and failure. A session id makes a late event from an old capture harmless.
- **The UI shows useful input diagnostics** — source policy, device-list generation, capture frame/duration/drop counters, and the bounded-buffer condition are visible without inventing fake controls.
- **Recording is an app policy** — after stop, the sample converts the bounded f32 buffer to PCM-16 WAV and writes it through `fx.writeFile`. The SDK primitive does not prescribe WAV, VAD, transcription, note storage, or a microphone UI.

## Boundaries

The sample’s output file is intentionally capped by the effects channel’s 1 MiB whole-file write: approximately 10.9 seconds at 48 kHz mono or 5.4 seconds stereo. It has no silence detection, compression, transcription, mixing, echo cancellation, background recording, or playback library. Those are distinct application-level policies.

The contribution is specifically an **audio-input** primitive. It does not enumerate or route audio output devices, so this sample intentionally does not include a cosmetic output picker. Output routing belongs to a separate cross-platform playback/output-device contract. Likewise, microphone access can be removed only by macOS in **System Settings > Privacy & Security > Microphone**; the sample tells users where to do that rather than pretending it can revoke OS consent itself.

## Tests

```sh
native test -Dplatform=null
```

The suite uses a synthetic input frame through the same `AudioInputSink` contract, verifies the consent-first transition and refusal state, confirms PCM never becomes an effect message, checks device selection and stale-session handling, and validates the exact WAV bytes queued for the file effect. No microphone hardware is required.
