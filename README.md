<div align="center">

# VoiceShot

### Timestamped speech notes for macOS

**Menu bar recording · Native SpeechAnalyzer · Daily transcript files · Local first**

[![macOS](https://img.shields.io/badge/macOS-26%2B-blue.svg)](#platform-support)
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](#build-from-source)
[![Speech](https://img.shields.io/badge/Speech-SpeechAnalyzer-blueviolet.svg)](#features)
[![Data](https://img.shields.io/badge/Data-local%20first-brightgreen.svg)](#privacy-and-data)
[![App](https://img.shields.io/badge/App-menu%20bar-lightgrey.svg)](#usage)

</div>

## Quick Start

### 1. Build the app

```bash
./scripts/build-app.sh
```

For a temporary unsigned development build:

```bash
ALLOW_UNSIGNED=1 ./scripts/build-app.sh
```

### 2. Open VoiceShot

```bash
open dist/VoiceShot.app
```

VoiceShot runs in the macOS menu bar. Click the microphone icon to start or stop recording.

### 3. Grant permissions

On first launch, macOS asks for:

| Permission | Why it is needed |
|---|---|
| **Microphone** | Capture your voice for local speech recognition |
| **Speech Recognition** | Use Apple speech recognition APIs |

If macOS asks you to quit and reopen VoiceShot after granting permission, choose `Quit & Reopen`.

---

## Why VoiceShot?

VoiceShot is a small macOS menu bar app for turning spoken notes into local text files.

Each recognized sentence is prefixed with the time when that speech segment started, accurate to the minute. This makes it useful for meetings, lectures, interviews, online calls, study sessions, and any workflow where the timeline matters.

Example output:

```text
13:20 How should we solve this problem?
13:22 Let's check the second condition first.
```

## Features

| | |
|---|---|
| **Menu bar recording** | Start and stop recording from the macOS menu bar |
| **Native transcription** | Uses macOS 26 `SpeechAnalyzer` and `SpeechTranscriber` |
| **Timestamped text** | Adds an `HH:mm` prefix based on the speech segment start time |
| **Daily transcript files** | Writes each day to `transcript-yyyyMMdd.txt` |
| **Structured events** | Also writes recognition events to `events.jsonl` |
| **Language setting** | Choose the speech recognition language in Settings |
| **Local storage** | Files are saved locally on your Mac |
| **Minimal permissions** | Uses microphone and speech recognition only |

## Usage

Click the VoiceShot microphone icon in the menu bar:

| Menu item | Action |
|---|---|
| `Start Recording` | Start microphone capture and speech recognition |
| `Stop Recording` | Stop recording and flush the remaining transcript |
| `Settings` | View the save path and change the recognition language |
| `Quit` | Exit VoiceShot |

While recording, the menu bar icon changes to a compact recording indicator.

## Output Files

Default save directory:

```text
~/Documents/VoiceShot
```

Generated files:

```text
VoiceShot/
  transcript-20260630.txt
  transcript-20260701.txt
  events.jsonl
```

| File | Purpose |
|---|---|
| `transcript-yyyyMMdd.txt` | Human-readable daily transcript |
| `events.jsonl` | Structured event log for later search, indexing, or analysis |

Transcription may appear with a short delay because VoiceShot writes finalized speech recognition segments. Stopping the recording flushes the remaining text.

## Settings

VoiceShot currently supports:

| Setting | Default |
|---|---|
| Speech language | `zh-CN` |
| Save path | `~/Documents/VoiceShot` |

The save path is displayed in Settings and is fixed for the current version.

## Privacy And Data

VoiceShot is local first:

| | |
|---|---|
| **No account** | No signup or login required |
| **No cloud dashboard** | VoiceShot does not run a hosted backend |
| **Local files** | Transcripts are written under `~/Documents/VoiceShot` |
| **User-controlled data** | You can delete the output folder at any time |

Speech recognition uses Apple's native speech recognition framework. Depending on system language, installed models, and macOS behavior, recognition may use Apple-provided on-device or system-managed speech services.

## Platform Support

| Platform | Status |
|---|---|
| macOS 26+ | Supported |
| iPhone / iPad | Not supported |
| Windows / Linux | Not supported |

VoiceShot requires macOS 26 because it uses the newer `SpeechAnalyzer` API.

## Build From Source

Requirements:

| Tool | Version |
|---|---|
| macOS | 26+ |
| Xcode | 26+ |
| Swift | 6.2+ |

Run from source:

```bash
swift run VoiceShot
```

Build a `.app` bundle:

```bash
./scripts/build-app.sh
open dist/VoiceShot.app
```

### Code Signing

`build-app.sh` tries to find an Apple code signing identity automatically.

It prefers:

1. `Apple Development`
2. `Developer ID Application`

You can also provide one explicitly:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

For local development without a signing identity:

```bash
ALLOW_UNSIGNED=1 ./scripts/build-app.sh
```

Unsigned builds are useful for development, but macOS privacy permissions may need to be granted again after rebuilds.

## Troubleshooting

### Microphone permission is missing

Open:

```text
System Settings -> Privacy & Security -> Microphone
```

Enable `VoiceShot`, then quit and reopen the app if macOS asks you to.

### Transcript appears delayed

VoiceShot writes finalized speech segments, so text may appear after a short delay. Use `Stop Recording` to finalize the current recording session.

### No supported speech model

Make sure the selected language is supported by macOS speech recognition on your system. You can switch languages from `Settings`.

## Uninstall

1. Quit `VoiceShot` from the menu bar.
2. Delete the app bundle:

   ```text
   dist/VoiceShot.app
   ```

3. Delete local transcripts if needed:

   ```bash
   rm -rf "$HOME/Documents/VoiceShot"
   ```
