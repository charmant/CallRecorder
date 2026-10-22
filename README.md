<p align="center"><img src="docs/icon.png" width="128" alt="CallRecorder icon"></p>

<h1 align="center">CallRecorder</h1>

<p align="center">Record FaceTime and Telegram calls on your Mac as two separate tracks and get an on-device transcript — from the menu bar.</p>

## What it is

CallRecorder lives next to the clock. During a call, click **Record Call** and it captures:

- **your voice** — from the microphone you're using (AirPods, for example);
- **the other side** — the audio of the calling app itself, not a microphone in the room, so no speakerphone needed.

When the call ends, recording stops on its own after 3 seconds. The two tracks are saved separately and
also mixed into a single file for listening. Then the call is transcribed right on your Mac — because the
tracks are separate, the transcript knows exactly who said what.

## Features

- Detects calls automatically: FaceTime (including FaceTime Audio, which macOS 27 runs through the Phone app) and Telegram Desktop.
- Two sample-aligned tracks plus a mixed `conversation.m4a`.
- Stops automatically when the call ends.
- On-device transcription after every call (Parakeet via FluidAudio on the Neural Engine): `transcript.md` with a
  time range and a speaker on every line. Starts by itself, can be stopped, and works for older recordings too.
- Live levels for you and them, and a warning if the other side goes silent for too long.
- History: recent recordings right in the menu, plus a History window with search and filters.
- Player with a conversation waveform — them on top, you below. Click anywhere on it to jump there.
- Transcripts open in the app's own window: the conversation waveform on top, every line with its time and
  speaker, click a time to play from there, the current line follows playback, search and copy.
- In the History window, click a transcript line to play from that moment; search covers transcripts.
- Liquid Glass UI built from native macOS 26 components.
- Everything stays local: no servers, no analytics.

## Requirements

- macOS 26 Tahoe or later. Tested on macOS 27, MacBook Pro M1 Pro, AirPods 3.
- The call has to run **on this Mac**. A call on your iPhone isn't visible to the app, even with the Mac nearby.
- The first transcription downloads the speech model once (~610 MB).

## Install

### Download

Get `CallRecorder-0.1.dmg` from [Releases](https://github.com/charmant/CallRecorder/releases) and drag the app
to Applications.

The build isn't notarized by Apple, so macOS blocks the first launch. Open
System Settings → Privacy & Security → **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/CallRecorder.app
```

### Build from source

Requires Xcode 26 or later.

```bash
git clone https://github.com/charmant/CallRecorder.git
```

```bash
cd CallRecorder && ./scripts/install.sh
```

The script builds the app, installs it to `~/Applications` and launches it. It signs with the first
Apple Development certificate it finds, or ad-hoc if there is none.

On the first recording macOS asks for two permissions: **Microphone** (your track) and
**System Audio Recording** (their track).

## Usage

1. Start a call in FaceTime or Telegram on your Mac. The menu bar icon changes from a waveform to a phone.
2. Open the menu and click **Record Call** (or press Return). The menu shows a timer and both levels.
3. Hang up — 3 seconds later the recording is saved automatically. To stop earlier: **Stop** or ⌘.
4. The recording shows up under **Recent** and is transcribed in the background (about 1.5 minutes per hour of
   call on an M1 Pro). The ✕ next to the progress bar stops it; **Transcribe** in a recording's menu starts it again.
5. **History…** (⌘Y) lists all recordings by day, with the transcript of the selected one.

## What gets saved

Each recording is a folder `~/Calls/<date time> <FaceTime|Telegram>/`:

| File | Contents |
| --- | --- |
| `local.caf` | your microphone |
| `remote.caf` | the calling app's audio (them) |
| `conversation.m4a` | both tracks mixed for listening |
| `session.json` | devices, formats, duration, detected issues, events |
| `transcript.md` | the transcript: `[05:12–05:14] Them: …`, one line per utterance |
| `transcript.json` | the same with exact times, for search and future summaries |
| `waveform.json` | waveform for the player |
| `events.log` | what happened during the recording |

## How it works

```text
Them → FaceTime / Telegram → headphones
                │
                └─ Core Audio process tap ──┐
You  → microphone ───────────────────────────┤  one private aggregate device
                                             │
                                             └→ IOProc → two lock-free buffers → local.caf, remote.caf
                                                                                ↓ after stop
                                                                  conversation.m4a, waveform.json
```

- **Them.** `AudioHardwareCreateProcessTap` captures the calling processes' audio in `unmuted` mode, so you
  keep hearing the call. For FaceTime the voice is played by the system daemon `avconferenced`, not by the
  app itself — found from the diagnostics log of a real call.
- **You.** The microphone is part of the same aggregate device and drives its clock; the tap follows it
  (drift compensation). Both tracks arrive in one IOProc, so they line up sample-for-sample without manual
  syncing: on a one-hour call their length matched wall-clock time within 0.05 s.
- **Call start and end** are detected by whether the calling app holds the microphone
  (`kAudioProcessPropertyIsRunningInput`).
- **Reliability.** The IOProc only copies into ring buffers; a separate thread writes to disk. CAF headers
  are updated on every write, so audio already recorded stays readable after a crash. Lost frames are
  replaced with silence so the tracks never drift apart, and are noted in `session.json`.
- **Permissions.** There's no public API to check system audio access, and without it the tap silently
  delivers zeros. So the app uses the private `TCCAccessPreflight` / `TCCAccessRequest`, like
  [AudioCap](https://github.com/insidegui/AudioCap). That also means it isn't App Store material.

- **Transcription.** Each track is cut into utterances at pauses, and every utterance is transcribed on its own
  with [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) through
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (Core ML, Neural Engine). Short clips with no Cyrillic
  at all are dropped — that removes the "Yeah" / "Mm-hmm" the model hears in noise. Before choosing it we compared
  Whisper (whisper.cpp, WhisperKit), Parakeet and several setups on a real call; Parakeet made about half the errors
  of Whisper large-v3-turbo on the human-checked part.

Details, the model comparison, the verification log and the test protocol are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Limitations

- Start recording during the call: the source is found by the process that holds the microphone.
- Your microphone is recorded even when you mute it in FaceTime or Telegram — it's a separate capture.
- With the AirPods microphone the whole recording runs at the headset rate (16–24 kHz). Fine for speech.
- In a group call everyone on the other side ends up in one track.
- FaceTime is verified on a real one-hour call; Telegram not yet.
- Transcripts are good but not perfect: the model sometimes writes an English term in Cyrillic letters, drops a
  one-word reply, or mishears a rare name. It has been checked on one Russian call with English terms so far.

## Legal

In many places recording a conversation without the other person's consent is illegal, and in some
(Germany, for example) it's a criminal offence. Tell the other side the call is being recorded.

## Roadmap

- Call summaries: topics, decisions, action items.
- A personal glossary of names and terms to fix their spelling in transcripts.

## Credits

- Speech recognition: [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) by moondream, based on
  [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA — both CC-BY-4.0. The model is
  downloaded at first use and is not part of this repository.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by Fluid Inference — Apache-2.0.
- The system-audio permission check follows [AudioCap](https://github.com/insidegui/AudioCap) by Guilherme Rambo.
