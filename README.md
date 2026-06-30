<div align="center">

# VoiceShot

### Timestamped speech notes for macOS

**Menu bar recording · Native SpeechAnalyzer · Daily transcript files · Local first**

### [Download VoiceShot.dmg →](https://github.com/qteqpid/voice-shot/blob/master/releases/latest/download/VoiceShot.dmg)

[![Download](https://img.shields.io/badge/Download-VoiceShot.dmg-2ea44f.svg)](https://github.com/qteqpid/voice-shot/tree/master/releases/latest/download/VoiceShot.dmg)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue.svg)](#platform-support)
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](#build-from-source)
[![Speech](https://img.shields.io/badge/Speech-SpeechAnalyzer-blueviolet.svg)](#features)
[![Data](https://img.shields.io/badge/Data-local%20first-brightgreen.svg)](#privacy-and-data)
[![App](https://img.shields.io/badge/App-menu%20bar-lightgrey.svg)](#usage)

</div>

## Quick Start

### 1. Download the DMG

Download the latest installer:

```text
https://github.com/qteqpid/voice-shot/blob/master/releases/latest/download/VoiceShot.dmg
```


### 2. Install VoiceShot

Open `VoiceShot.dmg`, then drag `VoiceShot.app` into `Applications`.

### 3. Launch VoiceShot

Open `VoiceShot` from `Applications`. The app runs in the macOS menu bar.

Click the microphone icon in the menu bar to start or stop recording.

### 4. Grant permissions

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

## Install Notes

VoiceShot is distributed as a macOS DMG installer:

```text
VoiceShot.dmg
```

The DMG contains:

| Item | Purpose |
|---|---|
| `VoiceShot.app` | The menu bar app |
| `Applications` | Shortcut target for drag-and-drop installation |

For normal use, install the app into:

```text
/Applications/VoiceShot.app
```

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

Build a DMG installer:

```bash
./scripts/package-dmg.sh
```

For a temporary unsigned local DMG:

```bash
ALLOW_UNSIGNED=1 ./scripts/package-dmg.sh
```

### Code Signing

`build-app.sh` tries to find an Apple code signing identity automatically for local app builds.

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

For release DMG packaging, `package-dmg.sh` looks for a local `Developer ID Application` certificate automatically. If exactly one certificate is found in your keychain, the script uses it. If none or multiple are found, it prints the next action.

You can also set the identity explicitly:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh
```

If you have a notarization profile configured:

```bash
NOTARY_PROFILE="your-notary-profile" ./scripts/package-dmg.sh
```

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
2. Delete the installed app:

   ```text
   /Applications/VoiceShot.app
   ```

3. Delete local transcripts if needed:

   ```bash
   rm -rf "$HOME/Documents/VoiceShot"
   ```
