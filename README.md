# Ballast

A macOS menu-bar app that keeps every track at the same comfortable level — the macOS equivalent of Windows' *Loudness Equalisation*, but one that **learns your music**. Set the volume once and stop reaching for it: a quiet acoustic track and a brick-walled pop single land at the same loudness, while the dynamics *within* each track are left untouched.

Ballast measures each track's true loudness as you listen and remembers it, so the more you play, the more of your library it knows — and known tracks are levelled perfectly from the very first note.

## Requirements

- macOS 15 (Sequoia) or later.

Ballast uses Core Audio process taps (macOS 14.2+) and the `Synchronization` framework (15+), so there's no virtual audio driver and nothing to install into the system.

## How It Works

Every app's audio is mixed and sent to your output device. Ballast places a **Core Audio process tap** on that mix — the modern, driver-free mechanism Apple provides for system audio — measures its loudness, applies a gentle gain, and plays the result back through your normal output device. Your selected output stays selected; there's nothing to route.

Loudness is measured with **EBU R128 / ITU-R BS.1770** (LUFS) — the same standard streaming services and broadcasters normalise to — and steered toward your **comfort level** (−16 LUFS by default).

**It learns.** Ballast watches for track changes broadcast by Apple Music and Spotify. The first time it hears a track it measures the whole thing (once you've played ≥ 80% of it) and stores its loudness, keyed by the track's identity. Every time after that, it recognises the track and applies one fixed, dynamics-preserving gain **from the first sample** — no ramp, no guesswork.

| Situation | What Ballast does |
|-----------|-------------------|
| A **known** track (heard before) | Applies its learned level instantly; full dynamics intact |
| A **new** track | Levels it live (anchored to its loudest passage so nothing blasts) and learns it for next time |
| Loud vs quiet tracks | Land at the same comfortable loudness |
| Dynamics within a track | Preserved — Ballast does not compress the quiet-to-loud swing |

When you switch output device — headphones, a speaker — Ballast rebuilds itself around the new device automatically. Your learned library carries over untouched: a track's loudness is measured from the source, before playback, so nothing is ever relearned per device.

## Menu Bar

The waveform icon shows whether levelling is on. Click it for:

- **Level Loudness** — turn levelling on/off
- Live status — the current track's loudness and the adjustment being applied
- **This track: known / learning…** and a running **N tracks learned** count
- **Re-level Now** — force a re-measure of the current audio (browser/YouTube sources auto-relevel on their own; this is the manual override)
- **Check for Updates…**, **Settings…**, **About**

The current track's title can optionally be shown to the right of the icon (Settings → Menu Bar) — handy as a lightweight now-playing display, so it can stand in for a separate one.

## Settings

- **Comfort level** — a simple *Quieter ←→ Louder* slider (the loudness target; −16 LUFS by default)
- **Maximum adjustment** — caps how far Ballast will push any track (±12 dB by default)
- **Now** — live output device, this track's loudness, and the current adjustment
- **Show current track title** — display the playing track's title to the right of the menu-bar icon, with an adjustable maximum length; longer titles are trimmed at a word boundary with an ellipsis (UTF-8 safe), and nothing is shown while paused or stopped. Off by default.
- **Permission** — audio-capture status, with a button to grant it or open System Settings
- **Show icon in menu bar** (macOS 14–15 only), optional **background pill**, and **Launch at Login**

Auto-updates are handled by Sparkle.

## Permissions

### Audio capture (required)

Reading the system audio mix goes through macOS's audio-capture privacy gate (its own category, separate from the microphone). A short welcome panel on first launch explains this. You're prompted the first time you turn levelling on; if you miss it, grant it under **System Settings → Privacy & Security**.

Audio is measured and processed **entirely on-device, in real time**. Ballast never records, stores, or transmits any audio, and has no telemetry. The only thing written to disk is your loudness library (track loudness values + titles) at `~/Library/Application Support/Ballast/library.json`.

### Automation (optional)

The first time levelling starts with Apple Music or Spotify playing, macOS asks to let Ballast **control** that app. It's used only to read the *currently playing* track at start-up, so Ballast can apply that track's learned level immediately instead of waiting for the next track change. Decline it and Ballast just waits for the next change — everything else works the same.

## Building from Source

Ballast is a Swift Package (no Xcode project).

```bash
cd ~/Desktop/"Jorvik Software"/Ballast
gmake build
open .build/Ballast.app
```

Requires GNU Make 4.x (`brew install make` → `gmake`). Signed, notarised releases are produced through the shared `release.mk` pipeline.

## How It Works (Technical)

Driver-free, two real-time callbacks sharing one hardware clock:

![How Ballast levels your audio: app audio is captured by a muted process tap, buffered through an aggregate device and lock-free ring clocked by the output device, levelled per track by the loudness engine that learns each track into an on-disk library, then played to your speakers.](assets/how-it-works.svg)

- A **global process tap** (`AudioHardwareCreateProcessTap`, `.mutedWhenTapped`, excluding Ballast itself) captures the system mix and mutes its direct path, so you hear only the processed version.
- A **private aggregate device** clocked by the real output device carries the tap; an input IOProc drains it into a lock-free ring, and an output IOProc on the real device applies the DSP and plays it. Both callbacks run on the same clock, so the ring only absorbs their phase offset.
- The **DSP** K-weights the signal (BS.1770, coefficients derived per sample-rate), runs a gated **integrated-loudness meter** to learn the whole-track value, and applies either the learned fixed gain (known track) or a live loud-anchored gain (new track), followed by a true-peak look-ahead limiter that 4x-oversamples each channel to hold inter-sample peaks under −1 dBFS (not just sample peaks).
- **Track changes** come from the public `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged` distributed notifications — reliable across gapless playback, and immune to a track's own silent passages. (The general MediaRemote framework is entitlement-gated for third-party apps since macOS 15.4, so Ballast doesn't rely on it.)

Nothing persists in the system — the graph exists only while levelling is on, and quitting removes it entirely.

## Limitations

- Automatic per-track learning and re-levelling cover **Apple Music** and **Spotify** (the sources that broadcast track changes). Other sources — browser/YouTube audio — are levelled live and **auto-relevel** when the content changes to a noticeably different level (a heuristic, since there's no track signal to key off); **Re-level Now** still forces it immediately.
- The very first play of any track uses the live pass (nothing is known yet); it's learned for every play after.

---

Ballast is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
