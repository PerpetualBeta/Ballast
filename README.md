# Ballast

A macOS menu-bar app that keeps every track at the same comfortable level — the macOS equivalent of Windows' *Loudness Equalisation*, but one that **learns your music**. Set the volume once and stop reaching for it: a quiet acoustic track and a brick-walled pop single land at the same loudness, while the dynamics *within* each track are left untouched.

Ballast measures each track's true loudness as you listen and remembers it, so the more you play, the more of your library it knows — and known tracks are levelled perfectly from the very first note.

## Requirements

- macOS 15 (Sequoia) or later.

Ballast uses Core Audio process taps (macOS 14.2+) and the `Synchronization` framework (15+), so there's no virtual audio driver and nothing to install into the system.

## How It Works

Every app's audio is mixed and sent to your output device. Ballast places a **Core Audio process tap** on that mix — the modern, driver-free mechanism Apple provides for system audio — measures its loudness, applies a gentle gain, and plays the result back through your normal output device. Your selected output stays selected; there's nothing to route.

Loudness is measured with **EBU R128 / ITU-R BS.1770** (LUFS) — the same standard streaming services and broadcasters normalise to — and steered toward your **comfort level** (−16 LUFS by default).

**It learns — and keeps itself honest.** Ballast watches for track changes broadcast by Apple Music and Spotify. The first time it hears a track it measures the whole thing (once you've played ≥ 80% of it) and stores its loudness, keyed by the track's identity — listening to **only that app's audio** while it learns, so a notification or system beep can never skew the value. Every time after that it recognises the track and applies one fixed, dynamics-preserving gain **from the first sample** — no ramp, no guesswork — while quietly re-measuring in the background and nudging the stored value if it has drifted. The library keeps itself accurate the more you listen.

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
- **Re-level Now** — force a re-measure of the current audio (browser/YouTube sources auto-relevel on their own; this is the manual override)
- **Visualiser…** — open the real-time music visualiser
- **Check for Updates…**, **Settings…**, **About**

The live level readout (source loudness, adjustment, target, learned count) lives in the visualiser's **Now Playing** mode and **Settings → Now**, keeping the menu to controls only.

The current track's title can optionally be shown to the right of the icon (Settings → Menu Bar) — handy as a lightweight now-playing display, so it can stand in for a separate one.

## Settings

- **Comfort level** — a simple *Quieter ←→ Louder* slider (the loudness target; −16 LUFS by default)
- **Maximum adjustment** — caps how far Ballast will push any track (±12 dB by default)
- **Now** — live output device, this track's loudness, and the current adjustment
- **Library** — the number of tracks Ballast has learned, plus two resets: **Reset Play Counts & Love** zeroes every track's play count and "love" rating while keeping the learned loudness (levelling unaffected); **Reset Learned Library** forgets everything — loudness and all — and relearns from scratch as you listen
- **Visualiser** — choose the style, optionally tint it from your desktop wallpaper (Match or Complement), and keep the window on top
- **Show current track title** — display the playing track's title to the right of the menu-bar icon, with an adjustable maximum length; longer titles are trimmed at a word boundary with an ellipsis (UTF-8 safe), and nothing is shown while paused or stopped. Off by default.
- **Permission** — audio-capture status, with a button to grant it or open System Settings
- **Show icon in menu bar** (macOS 14–15 only), optional **background pill**, and **Launch at Login**

Auto-updates are handled by Sparkle.

## Visualiser

A real-time visualiser of whatever's playing. Because it's driven by the same system-audio tap, it reacts to **any** app — Music, Spotify, a browser, a game. Open it from the menu (**Visualiser…**) or **Settings → Visualiser**.

It's a chromeless, resizable window with the system's standard rounded corners: drag anywhere to move it, right-click for the menu, press the arrow keys to cycle styles, or **f** for full screen. It only renders while open, so there's no cost when it's closed.

Six styles:

- **Aurora** — a calm, generative aurora that drifts and swells with the music.
- **Dancer** — a nightclub floor drawn in pure math: abstract, smoke-like figures sway through a single hard key light, their pace ebbing and flowing with the music's energy, with a mirrored waveform riding over the top.
- **Spectrum** — an LED-style analyser with slow-falling peak-hold caps.
- **Oscilloscope** — smooth waveform traces, stacked by frequency band.
- **VU Meters** — a pair of analogue VU meters with ballistic needles and a real numbered dB scale.
- **Now Playing** — the album artwork as a backdrop and hero, with the track details, a **“love” rating** (hearts, from how often you play a track versus the rest of your library), **play count**, and a **progress bar** (time elapsed, time remaining, and track length), plus Ballast's live level readout (source loudness, adjustment, target, known/learning, learned count), the current output device and — on wireless headphones or speakers — its **battery level**. A home for those stats outside the menu bar. When paused it holds the track (dimmed); when nothing's playing it settles into a calm, wallpaper-tinted drifting gradient. Cover art comes from the player, with an online lookup by title and artist as a fallback for streaming tracks that carry none (some Apple Music playlist items).

The four generative styles are procedural Metal shaders (no image assets); the VU meters are vector-drawn with Core Graphics and Now Playing is a SwiftUI view. **Colour** (Settings → Visualiser) can follow your desktop wallpaper — *Match* its dominant tone or take its *Complement* — re-deriving when you change wallpaper or Space. **Keep window on top** floats it above other windows.

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

![How Ballast levels your audio: app audio is captured by a muted process tap — system-wide, or just the music app while learning — buffered through an aggregate device and lock-free ring clocked by the output device, levelled per track by the loudness engine that learns and self-maintains an on-disk library, then played to your speakers.](assets/how-it-works.svg)

- A single **Core Audio process tap** (`AudioHardwareCreateProcessTap`, `.mutedWhenTapped`) captures audio and mutes its direct path, so you hear only the processed version. It normally taps the **whole system** (everything but Ballast); while it's *learning* a new Apple Music / Spotify track it taps **only that app**, so no other sound can pollute the value being measured, then switches back once the track is known. Only one tap ever runs — a second tap on the same app would divert its audio — so the graph is rebuilt to swap between the two.
- A **private aggregate device** clocked by the real output device carries the tap; an input IOProc drains it into a lock-free ring, and an output IOProc on the real device applies the DSP and plays it. Both callbacks run on the same clock, so the ring only absorbs their phase offset. A lightweight **watchdog** rebuilds the graph if the tap ever falls silent mid-playback; if the music-only tap can't deliver, it reverts to the system-wide tap and retries the isolated one on a later track — backing off, and giving up only after repeated failures — so a transient Core Audio hiccup can't quietly stop learning for the rest of the session.
- The **DSP** K-weights the signal (BS.1770, coefficients derived per sample-rate), runs a gated **integrated-loudness meter** to measure the whole-track value, and applies either the learned fixed gain (known track) or a live loud-anchored gain (new track), followed by a true-peak look-ahead limiter that 4x-oversamples each channel to hold inter-sample peaks under −1 dBFS (not just sample peaks). A known track's stored value is refined each play as a capped running mean, so the library self-corrects any drift while one noisy play barely moves it.
- **Track changes** come from the public `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged` distributed notifications — reliable across gapless playback, and immune to a track's own silent passages. (The general MediaRemote framework is entitlement-gated for third-party apps since macOS 15.4, so Ballast doesn't rely on it.)

Nothing persists in the system — the graph exists only while levelling is on, and quitting removes it entirely.

## Limitations

- Automatic per-track learning and re-levelling cover **Apple Music** and **Spotify** (the sources that broadcast track changes). Other sources — browser/YouTube audio — are levelled live and **auto-relevel** when the content changes to a noticeably different level (a heuristic, since there's no track signal to key off); **Re-level Now** still forces it immediately.
- **Crossfade works against per-track levelling.** With Apple Music's *Crossfade* on (Settings → Playback → Song Transitions), the end of one track overlaps the start of the next for a few seconds, and Music reports the track change only part-way through that blend. During the overlap Ballast is still applying the *outgoing* track's level to the incoming one — so a quiet track fading into a much louder one can briefly come through above your comfort level, until the change is reported and the new track's own level takes over. Two differently-mastered tracks playing at once have no single correct level, so this is inherent to crossfading rather than something Ballast can fully fix. For levelling that's exact from the first note of every track, turn Crossfade off.
- The very first play of any track uses the live pass (nothing is known yet); it's learned for every play after.

---

Ballast is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
