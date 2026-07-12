import AppKit
import CoreAudio
import Foundation

/// Owns the Core Audio graph that does the levelling.
///
/// Driver-free, two real-time callbacks sharing one hardware clock:
///
///     every other app ──▶ global process tap (muted, self-excluded)
///                              │
///          input IOProc  ◀─────┘   (tap aggregate, clocked by the output device)
///                              ▼
///                        lock-free ring
///                              ▼
///          output IOProc  ─▶ LoudnessProcessor ─▶ default output device
///
/// The tap aggregate is clocked by the same output device the output IOProc
/// drives, so producer and consumer run in lockstep and the ring only absorbs
/// the phase offset. Our own re-injected output is excluded from the tap, so
/// there's no feedback loop.
///
/// The single tap normally captures the whole system mix. While *learning* an
/// unknown Music/Spotify track it switches to capture only that app, so system
/// sounds can't pollute the value being measured; it switches back to global
/// once the track is known. Only ever one tap runs — a second tap on the same
/// process would divert that app's audio — so the graph is rebuilt to swap it,
/// guarded by a self-heal watchdog that reverts to the global tap if the
/// music-only tap ever fails to deliver, then retries it (with back-off) on a
/// later track rather than abandoning learning for the whole session.
@MainActor
final class BallastEngine {

    private static let maxIOFrames = 8192
    private static let ringCapacitySeconds = 0.5
    private static let ringPrimeSeconds = 0.04

    private(set) var isActive = false
    private(set) var statusMessage = "Inactive"
    let processor = LoudnessProcessor()

    /// Called on the main thread whenever `isActive`/`statusMessage` change,
    /// so the menu-bar icon and menu can refresh — including after the async
    /// permission grant completes.
    var stateDidChange: (() -> Void)?

    /// Called on the main thread when the current track or its play/pause
    /// state changes, so the menu-bar title can refresh.
    var trackDidChange: (() -> Void)?

    /// A short, menu-friendly reason set when the engine stands itself down after
    /// an unrecoverable audio-system fault (see `standDown`), so the menu can say
    /// why levelling stopped rather than looking like the user turned it off.
    /// nil in normal operation; cleared the next time levelling starts cleanly.
    private(set) var faultMessage: String?

    private var tapID = AudioObjectID(0)
    private var inputAggregateID = AudioObjectID(0)
    private var outputDeviceID = AudioObjectID(0)
    private var inputProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?

    private var ring: AudioRingBuffer?
    private var inputScratch: UnsafeMutablePointer<Float>?
    private var outputScratch: UnsafeMutablePointer<Float>?
    private var scratchChannels = 0

    // A single global process tap captures the whole system mix (everything but
    // Ballast). Every track — known or new — is measured on it; the library's
    // self-correcting running mean keeps a value honest across plays, so there's
    // no need to isolate a first learn on a separate music-only tap (which cost
    // an audible graph rebuild on every switch into or out of an unknown track).

    private var outputDeviceName: String?
    private var outputDeviceUID: String?
    private let listenerQueue = DispatchQueue(label: "cc.jorviksoftware.Ballast.devicelistener")
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var debugTimer: Timer?

    // Self-heal watchdog: the capture graph can silently stop delivering audio —
    // the tap goes quiet even though the player is still playing. Core Audio
    // doesn't report it; the symptom is a stalled input IOProc or an abrupt drop
    // to silence. The hard part is NOT mistaking genuine musical silence (a
    // fade-out, a quiet interlude) for a broken tap — told apart by the descent
    // (music fades gradually; a dead tap cliffs to zero) and capped so it can
    // never thrash the graph.
    private static let watchdogInterval = 1.0
    // Well beyond the longest silence a *playing* track realistically contains,
    // so ordinary quiet passages and inter-song gaps never trip a false rebuild.
    private static let watchdogHealSeconds = 5.0
    // A dead tap delivers hard-zero samples; only genuine near-digital silence
    // should trip a heal. This floor sits far below any real quiet passage —
    // which never stays this low for whole seconds — so quiet music is never
    // mistaken for a broken tap. Deliberately well under the −60 dBFS *loudness*
    // gate (`hasAudioSignal`), which answers a different question.
    private static let watchdogSilenceDBFS = -90.0
    private static let watchdogSilencePeak = Float(pow(10.0, watchdogSilenceDBFS / 20.0))
    // The −60 dBFS loudness gate as a sample peak. The band between it and the
    // silence floor is "quiet but present" — where a fade-out or a soft passage
    // lives on its way down. A *dead* tap never passes through this band; it
    // cliffs from healthy straight to zero.
    private static let loudnessGatePeak = Float(pow(10.0, LoudnessProcessor.silenceGateLUFS / 20.0))
    // Consecutive quiet-but-present ticks that mark a *gradual* descent into
    // silence — i.e. a genuine musical fade (a fade-out or a quiet interlude),
    // never a broken tap. At the 1 s tick that's ≥ 2 s of ramp.
    private static let fadeRampTicks = 2
    // Cap on rebuild attempts for an *abrupt* silence within one episode, so a
    // silence we can't explain can never thrash the graph the way a fade once
    // did (11 rebuilds in 51 s). Resets when signal returns.
    private static let maxSilenceHeals = 2
    // A genuine, transient tap death recovers in a single rebuild. If the graph
    // still isn't delivering audio after this many rebuilds *in quick succession*,
    // the audio system itself is wedged — a known coreaudiod failure mode, often
    // needing a `killall coreaudiod` — and rebuilding only deepens it: each
    // attempt leaks an orphaned tap, and enough of them turn a recoverable stall
    // into a daemon-level wedge that even quitting the app can't clear. So past
    // this point we stand down instead (see `standDown`): pull the tap out, which
    // un-mutes the direct path so playback simply continues *unlevelled* rather
    // than falling silent, and wait for the user to re-enable once it's healthy.
    private static let maxConsecutiveHeals = 4
    // A heal-free run at least this long means the graph recovered, so the next
    // heal begins a fresh burst rather than counting toward a stand-down. Set
    // above the 1–5 s spacing between storm heals (a stall heals every tick, an
    // abrupt silence every `watchdogHealSeconds`) so a real storm always
    // accumulates in one burst, yet a lone transient followed by healthy playback
    // never does.
    private static let healBurstResetSeconds = watchdogHealSeconds * 2
    private var watchdogTimer: Timer?
    private var silentSeconds = 0.0
    private var fadingTicks = 0          // consecutive quiet-but-present ticks (a fade in progress)
    private var silenceHeals = 0         // rebuilds spent on the current abrupt-silence episode
    private var consecutiveHeals = 0     // global-tap rebuilds in the current burst (→ stand-down)
    private var lastHealAt = 0.0         // systemUptime of the last global-tap heal
    private var lastWatchdogWrites: UInt64 = 0

    private var trackChangeObservers: [NSObjectProtocol] = []
    // Apple Music / Spotify fire a burst of playerInfo notifications at a track
    // or playlist boundary (a station announces itself, a stopped/playing pair,
    // duplicates). Acting on each one rebuilds the audio graph, and several
    // rebuilds in a fraction of a second are audible as a click. So we coalesce:
    // record the latest state, settle briefly, then rebuild once for whatever is
    // actually playing when the dust settles. The window bridges the ~60–130 ms
    // gaps seen within a burst, yet stays well under a noticeable levelling delay.
    private static let trackChangeSettleWindow = 0.25
    private var pendingPlayerState: (playing: Bool, id: TrackIdentity?)?
    private var trackChangeSettleTimer: Timer?

    let library = LoudnessLibrary()
    private var currentKey: String?
    private var currentDurationMS = 0
    private var currentTitle: String?
    private var currentArtist: String?
    private var currentTrackStart = 0.0     // epoch seconds
    private var playerActive = false        // Music/Spotify actively playing

    var libraryCount: Int { library.count }

    /// Zero all play counts / "love" (keeps the learned loudness). Surfaced in
    /// Settings so a burst of shuffle-listening during learning-in can be
    /// cleared without wiping the levelling library.
    func resetPlayStats() {
        library.resetPlayStats()
        blLog("play stats reset — \(library.count) tracks kept, plays zeroed")
    }

    /// Wipe the entire learned library (loudness, plays, metadata) and start
    /// over. The current track, if any, immediately reverts to live learning so
    /// the fresh library begins rebuilding at once.
    func resetLibrary() {
        let had = library.count
        library.resetLibrary()
        if currentKey != nil { processor.beginTrack(knownIntegratedLUFS: nil) }
        blLog("learned library reset — \(had) tracks cleared, relearning from scratch")
    }

    var currentTrackKnown: Bool { processor.isKnownTrack }
    var currentTrackPlays: Int {
        guard let key = currentKey else { return 0 }
        return library.plays(key: key, durationMS: currentDurationMS)
    }
    var currentTrackLove: Double? {
        guard let key = currentKey else { return nil }
        return library.lovePercentile(key: key, durationMS: currentDurationMS)
    }
    /// True when the tap is carrying real audio (above the silence floor) —
    /// tells "playing" from paused/stopped for sources without track metadata
    /// (e.g. a browser).
    var hasAudioSignal: Bool { isActive && processor.meterSourceLoudness > Float(LoudnessProcessor.silenceGateLUFS) }
    private(set) var isPlaying = false
    var currentTrackTitle: String? { currentTitle }

    var currentOutputDeviceName: String? { outputDeviceName }

    // MARK: Enable / disable

    func start() {
        guard !isActive else { return }
        // Gate on the audio-capture permission first — without it the tap is
        // created successfully but only ever delivers silence.
        switch AudioCapturePermission.status {
        case .authorized:
            beginGraph()
        case .denied, .undetermined:
            statusMessage = "Requesting audio-capture permission\u{2026}"
            blLog("start: requesting audio-capture permission (status=\(AudioCapturePermission.status))")
            stateDidChange?()
            AudioCapturePermission.request { [weak self] granted in
                Task { @MainActor in self?.handlePermission(granted) }
            }
        }
    }

    private func handlePermission(_ granted: Bool) {
        guard !isActive else { return }
        if granted {
            beginGraph()
        } else {
            statusMessage = "Audio-capture permission denied — enable it in System Settings \u{25B8} Privacy & Security"
            isActive = false
            BallastSettings.isEnabled = false
            blLog("start: audio-capture permission denied")
            stateDidChange?()
        }
    }

    private func beginGraph() {
        // Fresh session: clear the self-heal burst counter.
        consecutiveHeals = 0
        lastHealAt = 0
        if buildGraph() {
            isActive = true
            faultMessage = nil
            BallastSettings.isEnabled = true
            registerDeviceChangeListener()
            registerTrackChangeObservers()
            setPlayerActive(false)
            startDebugTimerIfNeeded()
            startWatchdog()
            probeCurrentTrack()
            blLog("engine started — \(statusMessage)")
        } else {
            teardownGraph()
            isActive = false
            BallastSettings.isEnabled = false
            blLog("engine failed to start — \(statusMessage)")
        }
        stateDidChange?()
    }

    func stop() {
        guard isActive else { return }
        finalizeCurrentTrack()
        stopDebugTimer()
        stopWatchdog()
        unregisterDeviceChangeListener()
        unregisterTrackChangeObservers()
        teardownGraph()
        isActive = false
        BallastSettings.isEnabled = false
        statusMessage = "Inactive"
        faultMessage = nil
        outputDeviceName = nil
        isPlaying = false
        playerActive = false
        blLog("engine stopped")
        stateDidChange?()
    }

    func applySettings() {
        processor.apply(
            targetLoudness: BallastSettings.targetLoudness,
            maxGain: BallastSettings.maxGain
        )
    }

    /// Force a fresh per-track measurement of whatever is playing now. Used by
    /// the "Re-level now" menu command for sources that don't broadcast track
    /// changes (browsers, other players).
    func relevelNow() {
        guard isActive else { return }
        blLog("manual re-level")
        processor.triggerReacquire()
    }

    // MARK: Level the currently-playing track on start-up

    /// One-shot: ask a running Music/Spotify what is playing now and apply that
    /// track's learned level immediately, rather than waiting for the next
    /// track-change notification.
    /// Track whether Music/Spotify is the active source. The browser/YouTube
    /// auto-relevel fallback runs only when no such player is driving, so music
    /// dynamics can never trip it.
    private func setPlayerActive(_ active: Bool) {
        playerActive = active
        processor.autoRelevelEnabled = !active
    }

    private func probeCurrentTrack() {
        NowPlayingProbe.query { [weak self] result in
            guard let self, let result else { return }
            self.applyProbeResult(result)
        }
    }

    private func applyProbeResult(_ r: NowPlayingProbe.Result) {
        // A real notification (or a stop) may have arrived while the async query
        // ran — if so, it wins and we leave it alone.
        guard isActive, currentKey == nil else { return }
        let title = r.title.isEmpty ? nil : r.title
        let artist = r.artist.isEmpty ? nil : r.artist
        let key: String
        switch r.source {
        case .music:
            key = UInt64(r.trackID, radix: 16).map { "am:\(Int64(bitPattern: $0))" }
                ?? "cx:\(r.title)·\(r.artist)"
        case .spotify:
            key = "sp:\(r.trackID)"
        }
        isPlaying = true
        setPlayerActive(true)   // playerActive must be set before startTrack picks the tap
        startTrack(TrackIdentity(key: key, durationMS: r.durationMS, title: title, artist: artist))
        blLog("probe: applied current track \(title ?? "?") -> \(key)")
        trackDidChange?()
    }

    // MARK: Track-change signals (public, no MediaRemote entitlement needed)

    private func registerTrackChangeObservers() {
        guard trackChangeObservers.isEmpty else { return }
        let centre = DistributedNotificationCenter.default()
        // Apple Music (current + legacy iTunes name) and Spotify broadcast a
        // playerInfo notification on every track change — including gapless —
        // and never mid-track, so it's the reliable per-track trigger.
        let names = [
            "com.apple.Music.playerInfo",
            "com.apple.iTunes.playerInfo",
            "com.spotify.client.PlaybackStateChanged",
        ]
        for name in names {
            let obs = centre.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handlePlayerInfo(note) }
            }
            trackChangeObservers.append(obs)
        }
    }

    private func unregisterTrackChangeObservers() {
        trackChangeSettleTimer?.invalidate()
        trackChangeSettleTimer = nil
        pendingPlayerState = nil
        let centre = DistributedNotificationCenter.default()
        for obs in trackChangeObservers { centre.removeObserver(obs) }
        trackChangeObservers.removeAll()
    }

    private struct TrackIdentity {
        let key: String
        let durationMS: Int
        let title: String?
        let artist: String?
    }

    private func handlePlayerInfo(_ note: Notification) {
        guard isActive else { return }
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String) ?? ""
        // An empty state is treated as playing (both apps normally send one).
        let playing = state.isEmpty || state.caseInsensitiveCompare("Playing") == .orderedSame

        var id: TrackIdentity?
        if playing {
            guard let parsed = trackIdentity(note) else { return }
            // An Apple Music streaming station announces the *station itself* as a
            // pseudo-track with no duration (e.g. "…'s Station", heard 0s of 0s)
            // moments before the real song. Acting on it forces a needless
            // tap-swap rebuild, so ignore anything with no real duration.
            guard parsed.durationMS > 0 else {
                blLog("ignoring context entry \(parsed.key) (no duration)")
                return
            }
            id = parsed
        }

        // Coalesce the notification burst (see `trackChangeSettleWindow`): record
        // the latest state and (re)arm the settle timer. The graph is rebuilt just
        // once, in `applyPendingPlayerState`, for the track playing when it fires.
        pendingPlayerState = (playing: playing, id: id)
        trackChangeSettleTimer?.invalidate()
        trackChangeSettleTimer = Timer.scheduledTimer(withTimeInterval: Self.trackChangeSettleWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.applyPendingPlayerState() }
        }
    }

    /// Apply the player state that survived the settle window — exactly one graph
    /// rebuild per genuine change, no matter how many notifications the burst held.
    private func applyPendingPlayerState() {
        trackChangeSettleTimer?.invalidate()
        trackChangeSettleTimer = nil
        guard isActive, let pending = pendingPlayerState else { return }
        pendingPlayerState = nil

        guard pending.playing, let id = pending.id else {
            // Paused or stopped: hide the title (keep the track loaded so a resume
            // doesn't re-level/re-learn), and let auto-relevel take over in case
            // another source is now playing.
            setPlayerActive(false)
            if isPlaying { isPlaying = false; trackDidChange?() }
            return
        }

        setPlayerActive(true)
        if id.key == currentKey {
            // Same track: a duplicate notification, or a resume after pause.
            if !isPlaying { isPlaying = true; trackDidChange?() }
            return
        }

        finalizeCurrentTrack()               // learn the track that just ended
        startTrack(id)                       // apply/learn the new one
        isPlaying = true
        trackDidChange?()
    }

    private func startTrack(_ id: TrackIdentity) {
        currentKey = id.key
        currentDurationMS = id.durationMS
        currentTitle = id.title
        currentArtist = id.artist
        currentTrackStart = Date().timeIntervalSince1970

        // No graph rebuild on a track change — the single global tap already
        // carries every source. Only the DSP re-anchors per track (a smooth gain
        // change, not a tap swap), so transitions are seamless.
        let known = library.lookup(key: id.key, durationMS: id.durationMS)
        processor.beginTrack(knownIntegratedLUFS: known?.integratedLUFS)
        blLog("track ▶ \(id.title ?? "?") — \(id.key) known=\(known.map { String(format: "%.1f LUFS (×\($0.plays))", $0.integratedLUFS) } ?? "no")")
    }

    /// Fold the just-finished track's measured loudness into the library — but
    /// only once at least 80% of the track has actually been *heard* (measured
    /// audio, excluding pauses/silence). A whole-track integrated number is
    /// only trustworthy once nearly the whole track has played, and basing it
    /// on a percentage handles a 2-minute pop song and a 30-minute symphony
    /// alike. Where the app gives no duration, fall back to a content minimum.
    private static let learnCoverageFraction = 0.80
    private static let learnFallbackSeconds = 60.0

    private func finalizeCurrentTrack() {
        guard let key = currentKey else { return }
        defer { currentKey = nil }

        let measured = processor.measuredIntegratedLUFS
        let content = processor.measuredContentSeconds
        let durationSec = Double(currentDurationMS) / 1000.0
        let coverage = durationSec > 0 ? content / durationSec : 0
        let enough = durationSec > 0
            ? coverage >= Self.learnCoverageFraction
            : content >= Self.learnFallbackSeconds
        guard enough else {
            blLog("not counted \(key): heard \(Int(content))s of \(Int(durationSec))s (\(Int(coverage * 100))%)")
            return
        }
        let now = Date().timeIntervalSince1970
        let usable = measured.isFinite && measured > -70

        if usable {
            // Fold this play's whole-track loudness into the library — a seed for
            // a new track, self-maintenance for a known one. The whole-track
            // integrated value (measured on the global mix) is robust to a brief
            // system sound, and record()'s capped running mean corrects a genuine
            // drift over plays while one noisy pass barely moves an established
            // value — so no isolated first-learn is needed.
            library.record(key: key, integratedLUFS: measured, durationMS: currentDurationMS,
                           title: currentTitle, artist: currentArtist, now: now)
            blLog("\(processor.isKnownTrack ? "refined" : "learned") \(key): \(String(format: "%.1f LUFS", measured)) (heard \(Int(coverage * 100))%, library=\(library.count))")
        } else if processor.isKnownTrack {
            // Enough heard but no usable measurement — count the play (its "love"
            // grows) and keep the stored level.
            library.recordPlay(key: key, durationMS: currentDurationMS, now: now)
            blLog("played \(key): play counted, level kept (no usable measurement)")
        } else {
            blLog("not learned \(key): no usable measurement (\(Int(coverage * 100))%)")
        }
    }

    /// Extract a stable identity from a Music/Spotify playerInfo notification.
    private func trackIdentity(_ note: Notification) -> TrackIdentity? {
        let info = note.userInfo ?? [:]
        let name = info["Name"] as? String
        let artist = info["Artist"] as? String
        let album = info["Album"] as? String

        func composite() -> String? {
            let parts = [name, artist, album].compactMap { $0 }
            return parts.isEmpty ? nil : "cx:" + parts.joined(separator: "·")
        }

        if note.name.rawValue.contains("spotify") {
            let duration = (info["Duration (ms)"] as? NSNumber)?.intValue
                ?? (info["Duration"] as? NSNumber)?.intValue ?? 0
            let key = (info["Track ID"] as? String).map { "sp:\($0)" } ?? composite()
            guard let key else { return nil }
            return TrackIdentity(key: key, durationMS: duration, title: name, artist: artist)
        } else {
            // Apple Music / iTunes: PersistentID is an NSNumber (Int64).
            let pid = (info["PersistentID"] as? NSNumber)?.int64Value
                ?? (info["Library PersistentID"] as? NSNumber)?.int64Value
            let duration = (info["Total Time"] as? NSNumber)?.intValue ?? 0
            let key = pid.map { "am:\($0)" } ?? composite()
            guard let key else { return nil }
            return TrackIdentity(key: key, durationMS: duration, title: name, artist: artist)
        }
    }

    // MARK: Graph construction

    private func buildGraph() -> Bool {
        guard let device = CoreAudioSupport.defaultOutputDevice(),
              let deviceUID = CoreAudioSupport.deviceUID(device) else {
            statusMessage = "No audio output device"
            return false
        }
        outputDeviceID = device
        outputDeviceUID = deviceUID
        outputDeviceName = CoreAudioSupport.deviceName(device) ?? "Output"
        let deviceSampleRate = CoreAudioSupport.deviceSampleRate(device) ?? 48_000
        blLog("buildGraph: device=\(device) uid=\(deviceUID) name=\(outputDeviceName ?? "?") sr=\(deviceSampleRate)")

        guard let selfProcess = CoreAudioSupport.processObject(forPID: getpid()) else {
            statusMessage = "Couldn't identify audio process"
            return false
        }
        blLog("buildGraph: pid=\(getpid()) selfProcessObject=\(selfProcess)")

        // 1. The tap. A single global tap captures the whole system mix, excluding
        //    Ballast itself so there's no feedback loop; every track is measured on
        //    it. Mute behaviour is tunable via `defaults write
        //    cc.jorviksoftware.Ballast tapMuteBehavior -int {0|1|2}` (0 unmuted,
        //    1 muted, 2 muted-when-tapped); default 2.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfProcess])
        tapDescription.name = "Ballast"
        let muteRaw = (UserDefaults.standard.object(forKey: "tapMuteBehavior") as? Int) ?? 2
        let muteBehavior: CATapMuteBehavior = (muteRaw == 0) ? .unmuted : (muteRaw == 1 ? .muted : .mutedWhenTapped)
        tapDescription.muteBehavior = muteBehavior
        tapDescription.isPrivate = true

        var newTap = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard tapStatus == noErr, newTap != 0 else {
            statusMessage = tapStatus == kAudioHardwareIllegalOperationError
                ? "Audio-capture permission needed"
                : "Couldn't create audio tap (\(tapStatus))"
            return false
        }
        tapID = newTap
        blLog("buildGraph: tap created status=\(tapStatus) tapID=\(tapID) muteBehavior=\(muteRaw)")

        guard let tapUID = CoreAudioSupport.tapUID(tapID) else {
            statusMessage = "Couldn't read tap identity"
            return false
        }

        let tapFormat = CoreAudioSupport.tapStreamFormat(tapID)
        // The tap is drift-compensated to the aggregate clock (the output
        // device), so the delivered rate is the device rate; the tap's own
        // reported rate can differ.
        let channels = Int(tapFormat?.mChannelsPerFrame ?? 2)
        let sampleRate = deviceSampleRate
        blLog("buildGraph: tapUID=\(tapUID) tapFormat sr=\(tapFormat?.mSampleRate ?? -1) ch=\(tapFormat?.mChannelsPerFrame ?? 0) flags=\(tapFormat?.mFormatFlags ?? 0) → engine sr=\(sampleRate) ch=\(channels)")

        // 2. Aggregate clocked by the output device, carrying the tap. Same
        //    shape AudioCap uses for capture.
        let aggregateUID = "cc.jorviksoftware.Ballast.aggregate.\(getpid())"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ballast",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]

        var newAggregate = AudioObjectID(0)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard aggStatus == noErr, newAggregate != 0 else {
            statusMessage = "Couldn't create audio device (\(aggStatus))"
            return false
        }
        inputAggregateID = newAggregate
        blLog("buildGraph: input aggregate status=\(aggStatus) id=\(inputAggregateID)")

        // 3. Ring + scratch, DSP config.
        let capacity = max(4096, Int(sampleRate * Self.ringCapacitySeconds))
        let prime = Int(sampleRate * Self.ringPrimeSeconds)
        let newRing = AudioRingBuffer(capacityFrames: capacity, channels: channels, primeFrames: prime)
        ring = newRing
        scratchChannels = channels
        let scratchCount = Self.maxIOFrames * channels
        let inScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCount)
        let outScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCount)
        inScratch.initialize(repeating: 0, count: scratchCount)
        outScratch.initialize(repeating: 0, count: scratchCount)
        inputScratch = inScratch
        outputScratch = outScratch

        processor.configure(sampleRate: sampleRate, channelCount: channels)
        applySettings()

        // 4. Input IOProc: tap → ring.
        let ringCtx = Unmanaged.passUnretained(newRing).toOpaque()
        let ch = channels
        let maxF = Self.maxIOFrames
        let inputBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            let ring = Unmanaged<AudioRingBuffer>.fromOpaque(ringCtx).takeUnretainedValue()
            let frames = AudioBufferSupport.interleave(inInputData, into: inScratch, channels: ch, maxFrames: maxF)
            if frames > 0 {
                ring.write(inScratch, frames: frames)
                _ = ring.dbgWriteCallbacks.wrappingAdd(1, ordering: .relaxed)
                ring.setDbgInputPeak(AudioBufferSupport.peak(inScratch, count: frames * ch))
            }
        }
        var newInputProc: AudioDeviceIOProcID?
        let inProcStatus = AudioDeviceCreateIOProcIDWithBlock(&newInputProc, inputAggregateID, nil, inputBlock)
        guard inProcStatus == noErr, let inputProc = newInputProc else {
            statusMessage = "Couldn't install input processor (\(inProcStatus))"
            return false
        }
        inputProcID = inputProc

        // 5. Output IOProc on the real device: ring → DSP → speakers.
        let procCtx = Unmanaged.passUnretained(processor).toOpaque()
        let feedCtx = Unmanaged.passUnretained(VisualizerFeed.shared).toOpaque()
        let outputBlock: AudioDeviceIOBlock = { _, _, _, outOutputData, _ in
            let ring = Unmanaged<AudioRingBuffer>.fromOpaque(ringCtx).takeUnretainedValue()
            let proc = Unmanaged<LoudnessProcessor>.fromOpaque(procCtx).takeUnretainedValue()
            var frames = AudioBufferSupport.outputFrameCount(outOutputData, channels: ch)
            if frames > maxF { frames = maxF }
            let got = ring.readPrimed(into: outScratch, frames: frames)
            if got < frames {
                memset(outScratch + got * ch, 0, (frames - got) * ch * MemoryLayout<Float>.size)
            }
            proc.processInterleaved(outScratch, frames: frames)
            Unmanaged<VisualizerFeed>.fromOpaque(feedCtx).takeUnretainedValue().push(interleaved: outScratch, frames: frames, channels: ch)
            AudioBufferSupport.deinterleave(outScratch, frames: frames, channels: ch, into: outOutputData)
            _ = ring.dbgReadCallbacks.wrappingAdd(1, ordering: .relaxed)
        }
        var newOutputProc: AudioDeviceIOProcID?
        let outProcStatus = AudioDeviceCreateIOProcIDWithBlock(&newOutputProc, outputDeviceID, nil, outputBlock)
        guard outProcStatus == noErr, let outputProc = newOutputProc else {
            statusMessage = "Couldn't install output processor (\(outProcStatus))"
            return false
        }
        outputProcID = outputProc

        let inStart = AudioDeviceStart(inputAggregateID, inputProc)
        let outStart = AudioDeviceStart(outputDeviceID, outputProc)
        guard inStart == noErr, outStart == noErr else {
            statusMessage = "Couldn't start audio (in=\(inStart) out=\(outStart))"
            return false
        }
        blLog("buildGraph: started — inStart=\(inStart) outStart=\(outStart) capacity=\(capacity) prime=\(prime)")

        statusMessage = "Levelling — \(outputDeviceName ?? "output")"
        return true
    }

    private func teardownGraph() {
        outputDeviceUID = nil
        if outputDeviceID != 0, let proc = outputProcID {
            AudioDeviceStop(outputDeviceID, proc)
            AudioDeviceDestroyIOProcID(outputDeviceID, proc)
        }
        outputProcID = nil

        if inputAggregateID != 0, let proc = inputProcID {
            AudioDeviceStop(inputAggregateID, proc)
            AudioDeviceDestroyIOProcID(inputAggregateID, proc)
        }
        inputProcID = nil

        if inputAggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(inputAggregateID)
            inputAggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        outputDeviceID = 0

        // Free scratch and ring only after the IOProcs are destroyed.
        ring = nil
        inputScratch?.deallocate(); inputScratch = nil
        outputScratch?.deallocate(); outputScratch = nil
        scratchChannels = 0
    }

    // MARK: Diagnostics

    private func startDebugTimerIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
        processor.diagnosticsEnabled = true
        debugTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logDebugStats() }
        }
    }

    private func logDebugStats() {
        guard let ring else { return }
        blLog("io: writes=\(ring.dbgWriteCallbacks.load(ordering: .relaxed)) reads=\(ring.dbgReadCallbacks.load(ordering: .relaxed))"
            + " depth=\(ring.availableFrames) over=\(ring.dbgOverruns.load(ordering: .relaxed)) under=\(ring.dbgUnderruns.load(ordering: .relaxed))"
            + " inPeak=\(String(format: "%.4f", ring.dbgInputPeak)) outPeak=\(String(format: "%.4f", processor.dbgOutPeak))"
            + " frames=\(processor.dbgFrames) gain=\(String(format: "%.2f", processor.meterGainDB))dB srcLoud=\(String(format: "%.1f", processor.meterSourceLoudness))")
    }

    private func stopDebugTimer() {
        debugTimer?.invalidate()
        debugTimer = nil
        processor.diagnosticsEnabled = false
    }

    // MARK: Output-device changes

    private func registerDeviceChangeListener() {
        guard deviceChangeListener == nil else { return }
        deviceChangeListener = CoreAudioSupport.addDefaultOutputDeviceListener(queue: listenerQueue) { [weak self] in
            Task { @MainActor in self?.handleDeviceChange() }
        }
    }

    private func unregisterDeviceChangeListener() {
        if let block = deviceChangeListener {
            CoreAudioSupport.removeDefaultOutputDeviceListener(queue: listenerQueue, block)
            deviceChangeListener = nil
        }
    }

    private func handleDeviceChange() {
        // A new output device is a fresh Core Audio path — give the heal-burst
        // counter a clean slate rather than carrying a prior device's failures over.
        consecutiveHeals = 0
        lastHealAt = 0
        rebuildGraph(reason: "default output device changed")
    }

    /// Tear the graph down and build it afresh, preserving the current track's
    /// learned level. Shared by the output-device-change listener and the
    /// self-heal watchdog — both need exactly this recovery.
    private func rebuildGraph(reason: String) {
        guard isActive else { return }
        blLog("rebuilding graph — \(reason)")
        stopDebugTimer()
        stopWatchdog()
        teardownGraph()
        if buildGraph() {
            // Re-apply the current track's learned level so it keeps its gain
            // across the rebuild (which reset the DSP). The library itself is
            // untouched — loudness is the track's own, not the device's.
            if let key = currentKey {
                let known = library.lookup(key: key, durationMS: currentDurationMS)
                processor.beginTrack(knownIntegratedLUFS: known?.integratedLUFS)
            }
            startDebugTimerIfNeeded()
            startWatchdog()
        } else {
            teardownGraph()
            isActive = false
            BallastSettings.isEnabled = false
            stateDidChange?()
        }
    }

    // MARK: Self-heal watchdog

    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        silentSeconds = 0; fadingTicks = 0; silenceHeals = 0
        lastWatchdogWrites = ring?.dbgWriteCallbacks.load(ordering: .relaxed) ?? 0
        let t = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
        watchdogTimer = t
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        silentSeconds = 0; fadingTicks = 0; silenceHeals = 0
    }

    private func watchdogTick() {
        guard isActive, let ring else { return }
        // Only judge the graph dead while the player insists a track is playing —
        // a genuine pause/stop legitimately produces silence, as does a browser
        // that simply isn't making sound.
        guard playerActive, isPlaying else { silentSeconds = 0; fadingTicks = 0; silenceHeals = 0; return }

        let writes = ring.dbgWriteCallbacks.load(ordering: .relaxed)
        let inputFiring = writes != lastWatchdogWrites
        lastWatchdogWrites = writes

        // The input IOProc is hardware-clocked and fires continuously while the
        // graph is alive; a whole tick with no writes means the aggregate has
        // stalled — heal at once.
        if !inputFiring {
            heal(reason: "input IOProc stalled while playing")
            return
        }

        // Firing but not loud: the tap is alive yet quiet though the player says a
        // track is playing. The hard part is telling a *broken* tap (delivering
        // zeros) from *genuine* silence in the music — a fade-out, or a quiet
        // interlude mid-track (a real one cost 11 rebuilds in 51 s). The tell is
        // the descent: music fades *gradually* through the −60…−90 dBFS band; a
        // dead tap cliffs from healthy straight to zero, skipping it.
        let peak = ring.dbgInputPeak
        if peak > Self.loudnessGatePeak {
            // Clear signal — normal playback. Reset every silence tracker.
            silentSeconds = 0; fadingTicks = 0; silenceHeals = 0
        } else if peak > Self.watchdogSilencePeak {
            // Quiet but present: a fade in progress or a soft passage, not (yet)
            // hard silence. Count the ramp; don't accumulate toward a heal.
            silentSeconds = 0; fadingTicks += 1
        } else if fadingTicks >= Self.fadeRampTicks {
            // Hard silence we *faded* into — genuine musical silence, never a dead
            // tap. Leave the graph alone (and the meter intact, so a track that
            // fades out still measures its whole self and learns).
            silentSeconds = 0
        } else {
            // Hard silence with no fade before it — an abrupt drop that may be a
            // dead tap. Heal, but cap attempts so it can't thrash; wait for signal
            // to return (resets `silenceHeals`) before trying again.
            silentSeconds += Self.watchdogInterval
            if silentSeconds >= Self.watchdogHealSeconds {
                if silenceHeals < Self.maxSilenceHeals {
                    silenceHeals += 1
                    heal(reason: "tap silent \(Int(silentSeconds))s while playing (inPeak=\(String(format: "%.4f", peak)))")
                }
                silentSeconds = 0
            }
        }
    }

    /// Recover from a dead tap by rebuilding the graph. Counts rebuilds that come
    /// in quick succession: a lone transient recovers in one and the burst never
    /// grows, but a wedged audio system keeps failing — past the cap we stand down
    /// instead of thrashing (see `standDown`).
    private func heal(reason: String) {
        silentSeconds = 0
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHealAt > Self.healBurstResetSeconds { consecutiveHeals = 0 }
        lastHealAt = now
        consecutiveHeals += 1
        if consecutiveHeals >= Self.maxConsecutiveHeals {
            standDown(reason: reason)
            return
        }
        blLog("watchdog: \(reason) — self-healing (global tap rebuild \(consecutiveHeals)/\(Self.maxConsecutiveHeals))")
        rebuildGraph(reason: "global tap rebuild")
    }

    /// Give up after repeated rebuilds that never restored audio: the audio
    /// system is wedged and rebuilding only makes it worse (each attempt leaks an
    /// orphaned tap). Remove the tap — which un-mutes the direct path, so playback
    /// continues *unlevelled* instead of silent — go inactive, and surface why so
    /// the user can reset the audio system and turn levelling back on. Deliberately
    /// does NOT finalize the current track: the measurement during a wedge is
    /// silence and must never reach the library. `BallastSettings.isEnabled` is
    /// left on, so a relaunch (with a healthy audio system) resumes levelling on
    /// its own — this is a runtime fault, not the user choosing to switch off.
    private func standDown(reason: String) {
        blLog("watchdog: \(reason) — audio system wedged after \(consecutiveHeals) rebuilds; standing down. "
            + "Tap removed, audio restored (unlevelled). Turn Level Loudness back on once the audio system is "
            + "healthy — quitting the audio app, or Terminal's \u{201C}killall coreaudiod\u{201D}, clears the wedge.")
        stopDebugTimer()
        stopWatchdog()
        unregisterDeviceChangeListener()
        unregisterTrackChangeObservers()
        teardownGraph()
        isActive = false
        isPlaying = false
        playerActive = false
        consecutiveHeals = 0
        statusMessage = "Levelling paused — the audio system needs a reset"
        faultMessage = "Paused \u{2014} audio system needs a reset"
        stateDidChange?()
    }
}
