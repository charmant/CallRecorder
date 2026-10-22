# CallRecorder: developer notes

## Layout

| File | What it does |
| --- | --- |
| `CaptureSession.swift` | tap + microphone in one aggregate device, IOProc, writer thread, `session.json`, mixdown |
| `TrackWriter.swift`, `SampleRingBuffer.swift` | a track: lock-free ring buffer → CAF |
| `AudioProcesses.swift`, `ProcessMonitor.swift` | Core Audio process list, call detection, diagnostics log |
| `Permissions.swift` | microphone (AVFoundation) and system audio (private TCC) |
| `AppModel.swift` | app state: recording, auto-stop, history, preview states for screenshots |
| `MenuView.swift`, `HistoryWindow.swift`, `TranscriptWindow.swift` | menu bar panel, History window, transcript window |
| `Playback.swift`, `ConversationTimeline.swift`, `Waveform.swift` | player and conversation waveform |
| `Mixdown.swift`, `History.swift` | mixing to m4a, loading history from `~/Calls` |
| `Transcriber.swift` | on-device transcription (FluidAudio + Parakeet Ultra), utterance splitting, transcript.md/json |

## Scripts

| Command | What it does |
| --- | --- |
| `./scripts/install.sh` | build, install to `~/Applications`, launch (refuses while a recording is running) |
| `./scripts/build-app.sh` | build `build/CallRecorder.app` only |
| `./scripts/package.sh` | build `dist/CallRecorder-<version>.dmg`, ad-hoc signed, for Releases |
| `./scripts/make-icon.sh` | redraw `Resources/AppIcon.icns` and `docs/icon.png` from `scripts/make-icon.swift` |

Self-test without a call — record 6 seconds of whole-system audio and quit:

```bash
open -W ~/Applications/CallRecorder.app --args --selftest 6
```

Transcription without the UI (the binary is `build/CallRecorder.app/Contents/MacOS/CallRecorder`):

| Flag | What it does |
| --- | --- |
| `--transcribe <recording folder>` | transcribe one recording directly and quit |
| `--enqueue-transcription <folder> [--stop-after N]` | the same path as after a call (queue, progress, unload); optionally stop after N s |
| `--transcribe-clips <folder of .wav> <out.json>` | transcribe ready-made clips as they are, for benchmarking |
| `--model v3\|ultra`, `--encoder int8\|int8-v2` | pick the Parakeet build for the commands above |

UI screenshots without a call — the app saves PNGs of its own windows. Glass and vibrancy colours don't
come through this way; these are layout snapshots:

```bash
open ~/Applications/CallRecorder.app --args --preview recording --preview-out /tmp/shots
```

States: `idle`, `call`, `recording`, `recording-ending`, `finishing`, `saved`, `problems`, `denied`,
`playing`, `transcribing`, `empty`, `history`, `history-playing`, `history-empty`, `transcript` (made-up lines).

## Capture pipeline

- Tap: `CATapDescription(stereoMixdownOfProcesses:)` on the calling processes, `muteBehavior = .unmuted`,
  `isPrivate = true`.
- Aggregate device: the only sub-device is the microphone (also the clock source); the tap uses drift
  compensation. IOProc input buffers: microphone streams first, then the tap. The first callback's layout is
  stored in `session.json` (`firstCallbackBuffers`).
- The output device is deliberately not part of the aggregate: AirPods have a microphone, and the aggregate
  would switch it on even when the call uses the Mac's microphone.
- `tapautostart` is off: with it, starting the aggregate waits for the first audio in the tap, so your voice
  isn't recorded while the other side is quiet. Found by the self-test: with no audio playing, IO never started.
- Files: CAF, 16-bit, at the aggregate's rate (the microphone's rate). `kAudioFilePropertyDeferSizeUpdates = 0`.
- If a cycle has no buffer for one track, silence of the same length is written to keep tracks aligned.
- `AVPlayer` exists only while something is playing, so the app doesn't hold an audio session otherwise.

## Transcription

- After a call is saved, the recording goes into a queue: one recording at a time, never while a call is being
  recorded; the model is unloaded when the queue is empty. Stopping discards the unfinished transcript.
- Each track is converted to 16 kHz mono and cut into utterances at pauses: 30 ms frames, a threshold 15 dB above the
  noise floor, pauses under 0.6 s stay inside an utterance, utterances under 0.4 s are dropped, 0.2 s of padding,
  anything longer than 14.5 s is split at its quietest point (one Core ML window is 15 s).
- Every utterance is transcribed on its own by Parakeet Ultra (FluidAudio, `AsrModelVersion.ultra`).
- `language:` is deliberately not passed to FluidAudio: its Russian token filter keeps only Cyrillic tokens and
  would turn English words such as "GitHub" or "JSON" into Cyrillic.
- A clip shorter than 1.6 s whose text has Latin letters and no Cyrillic is dropped — in a Russian call these were
  always noise or backchannels heard as "Yeah", "Nie", "Mm-hmm".
- Memory: the 16 kHz copies of both tracks dominate (about 1.45 GB peak for an hour); the model itself takes ~180 MB.

### How the model was chosen

On a 6-minute excerpt of a real FaceTime call (both tracks, 120 utterances, Russian with English terms), against a
human-checked reference for the first 17 utterances (131 words) and a consensus reference for the rest. WER after
normalization (lowercase, no punctuation, Russian yo folded into ye, hyphens as spaces):

| Setup | Human-checked | Whole excerpt | Time for the excerpt | Peak memory |
| --- | --- | --- | --- | --- |
| Parakeet v3, per utterance, parakeet-mlx (Python) + filter | 5.3% | 22.7% | 22.7 s | ~5.6 GB |
| **Parakeet Ultra, per utterance, FluidAudio + filter** | 9.2% | **19.7%** | **9.3 s** | **~180 MB** |
| Parakeet v3, FluidAudio int8 / int8-v2 encoder + filter | 12.2% / 13.7% | 23.8% / 24.1% | 9.4 / 11.1 s | ~180 MB |
| whisper.cpp large-v3-turbo + Silero VAD, whole track | 12.2% | 14.4% | 23.9 s | ~2 GB |
| Whisper per utterance (whisper.cpp, WhisperKit) | 17.6–24.4% | — | 145–339 s | — |
| whisper.cpp large-v3, whole track, no VAD | 23.7% | 84.5% | 167 s | — |

The "whole excerpt" reference was built by consensus of mostly-Whisper outputs, so it favours Whisper; on the
human-checked part Parakeet made about half of Whisper's errors. Per-utterance Whisper misdetected the language on
about a quarter of the short clips (and translated or garbled them); large-v3 without VAD looped on silence.
A literature review (Russian benchmarks, code-switching, Apple Silicon runtimes) pointed the same way and suggests
GigaAM-v3 as the next model to try for Russian accuracy, with Parakeet or Whisper for English terms.

## UI

Liquid Glass from native components: `.glassProminent` / `.glass` buttons, `Gauge` for levels, `GroupBox`
cards; the History window is `NavigationSplitView` + `Table` with day sections + `.inspector` +
`.searchable`. No custom `glassEffect`: the system draws the panel background. The only custom drawing is
the conversation waveform (`Canvas`), which VoiceOver sees as a slider.

## Verification log

**2026-10-22, self-test, built-in microphone and speakers.** Both tracks 5.92 s, sample-aligned.
The microphone lags the tap by ~43 ms — the acoustic path from speaker to microphone.

**2026-10-22, incoming FaceTime Audio call, AirPods 3 for both output and microphone, 57:56.**
- The source was detected automatically; only `avconferenced` ended up in the tap.
- 24 kHz (AirPods in headset mode), zero lost frames; track length matched wall-clock time within 0.05 s.
- Both tracks active at the same time 6 % of the time, cross-correlation 0.006: no bleed between tracks.
  Clipping: 139 samples in an hour.
- Screenshot sounds and Safari audio during the call didn't leak into the "them" track.
- Call end was detected within the same second (`avconferenced` stopped using the microphone).

What diagnostics showed: on macOS 27 the FaceTime Audio call window is the Phone app
(`com.apple.mobilephone`), but it only plays the ringtone. `avconferenced` keeps its output open all the
time, even without a call, so the call signal is specifically the microphone being in use.

**2026-10-22, self-test after the `tapautostart` fix.** 5 of 5 seconds recorded, both in silence and with sound.

**2026-10-22, transcription of the one-hour FaceTime call (57:56), Parakeet Ultra via FluidAudio, M1 Pro 16 GB.**
702 utterances (234 you, 468 them) in 89–92 s, peak 1.45 GB. Through the queue: stopping after 15 s left the
existing transcript untouched; a full run right after a stop succeeded in 3 of 4 tries — the one failure (a spurious
cancellation ~12 s in) is why a failed run is retried once.

## Real-call test protocol

1. FaceTime Audio, AirPods for both output and microphone: start recording during the call, talk for a
   couple of minutes with interruptions, hang up — recording must stop on its own.
2. Same for Telegram.
3. Pick the MacBook microphone in FaceTime/Telegram and in CallRecorder; AirPods only for listening.
4. Mute the microphone in the call for 10 seconds: the "you" track keeps recording (by design).
5. Play music in another app during the call — it must not appear in `remote.caf`.

## Diagnostics

`~/Calls/_diagnostics/audio-processes.log` — when each process started and stopped playing (`out`) or
recording (`in`) audio. It shows which process is responsible for the call.
