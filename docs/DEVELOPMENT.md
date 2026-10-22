# CallRecorder: developer notes

## Layout

| File | What it does |
| --- | --- |
| `CaptureSession.swift` | tap + microphone in one aggregate device, IOProc, writer thread, `session.json`, mixdown |
| `TrackWriter.swift`, `SampleRingBuffer.swift` | a track: lock-free ring buffer → CAF |
| `AudioProcesses.swift`, `ProcessMonitor.swift` | Core Audio process list, call detection, diagnostics log |
| `Permissions.swift` | microphone (AVFoundation) and system audio (private TCC) |
| `AppModel.swift` | app state: recording, auto-stop, history, preview states for screenshots |
| `MenuView.swift`, `HistoryWindow.swift` | menu bar panel and History window |
| `Playback.swift`, `ConversationTimeline.swift`, `Waveform.swift` | player and conversation waveform |
| `Mixdown.swift`, `History.swift` | mixing to m4a, loading history from `~/Calls` |

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

UI screenshots without a call — the app saves PNGs of its own windows. Glass and vibrancy colours don't
come through this way; these are layout snapshots:

```bash
open ~/Applications/CallRecorder.app --args --preview recording --preview-out /tmp/shots
```

States: `idle`, `call`, `recording`, `recording-ending`, `finishing`, `saved`, `problems`, `denied`,
`playing`, `empty`, `history`, `history-playing`, `history-empty`.

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
