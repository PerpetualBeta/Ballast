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
/// music-only tap ever fails to deliver.
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

    private var tapID = AudioObjectID(0)
    private var inputAggregateID = AudioObjectID(0)
    private var outputDeviceID = AudioObjectID(0)
    private var inputProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?

    private var ring: AudioRingBuffer?
    private var inputScratch: UnsafeMutablePointer<Float>?
    private var outputScratch: UnsafeMutablePointer<Float>?
    private var scratchChannels = 0

    /// Which processes the single tap captures. Only ONE tap runs at a time —
    /// a second tap on a process the first already taps would divert that app's
    /// audio, so isolation is done by *switching* the one tap, never adding one.
    private enum TapMode { case global, musicOnly }
    /// `.musicOnly` only while learning an unknown Music/Spotify track (so its
    /// measurement can't be polluted by system sounds); `.global` for known
    /// tracks, other sources, and when no music player is running.
    private var tapMode: TapMode = .global
    /// True when the current track's measurement is being taken in isolation
    /// (music-only tap) — the gate for folding it into the learned library.
    private var currentTrackIsolated = false
    /// Set false for the session if the music-only tap ever fails to deliver
    /// audio, so we don't repeatedly stutter into a tap that doesn't work here.
    private var musicOnlyTapViable = true

    private var outputDeviceName: String?
    private var outputDeviceUID: String?
    private let listenerQueue = DispatchQueue(label: "cc.jorviksoftware.Ballast.devicelistener")
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var debugTimer: Timer?

    // Self-heal watchdog: the capture graph can silently stop delivering audio —
    // the tap goes quiet even though the player is still playing (seen around
    // track boundaries). Core Audio doesn't report it; the only symptom is that
    // the input side has heard nothing for longer than any real gap in music.
    private static let watchdogInterval = 1.0
    // Well beyond the longest silence a *playing* track realistically contains,
    // so ordinary quiet passages and inter-song gaps never trip a false rebuild.
    private static let watchdogHealSeconds = 5.0
    // The processor's silence floor, expressed as a sample peak (≈ −60 dBFS).
    private static let watchdogSilencePeak = Float(pow(10.0, LoudnessProcessor.silenceGateLUFS / 20.0))
    private var watchdogTimer: Timer?
    private var silentSeconds = 0.0
    private var lastWatchdogWrites: UInt64 = 0

    private var trackChangeObservers: [NSObjectProtocol] = []

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
        // Fresh session: start on the global tap, and re-enable music-only
        // isolation (a prior session may have disabled it after a failure).
        tapMode = .global
        currentTrackIsolated = false
        musicOnlyTapViable = true
        if buildGraph() {
            isActive = true
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
        // A pause/resume changes which tap we want: music-only while actively
        // learning an unknown track, global when paused (so a browser is still
        // levelled) or otherwise.
        applyTapMode()
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

        guard playing else {
            // Paused or stopped: hide the title (keep the track loaded so a
            // resume doesn't re-level/re-learn), and let auto-relevel take over
            // in case another source is now playing.
            setPlayerActive(false)
            if isPlaying { isPlaying = false; trackDidChange?() }
            return
        }

        guard let id = trackIdentity(note) else { return }
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

        let known = library.lookup(key: id.key, durationMS: id.durationMS)
        processor.beginTrack(knownIntegratedLUFS: known?.integratedLUFS)
        blLog("track ▶ \(id.title ?? "?") — \(id.key) known=\(known.map { String(format: "%.1f LUFS (×\($0.plays))", $0.integratedLUFS) } ?? "no")")
        applyTapMode()
        // Learn only from a clean, isolated pass. If we couldn't get the
        // music-only tap this track stays on the global mix and isn't learned
        // (it retries next play), rather than banking a noise-polluted value.
        currentTrackIsolated = (tapMode == .musicOnly)
    }

    // MARK: Isolated music measurement

    /// The Core Audio process object for the app playing the current track, so
    /// the measurement tap captures only its audio (never system sounds).
    private func musicProcessObject() -> AudioObjectID? {
        guard let key = currentKey else { return nil }
        let bundleID = key.hasPrefix("sp:") ? "com.spotify.client" : "com.apple.Music"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        return CoreAudioSupport.processObject(forPID: app.processIdentifier)
    }

    /// The tap mode we *want* right now. Music-only only while actively learning
    /// an unknown Music/Spotify track — the sole window where system sounds
    /// would pollute a value being measured. Everything else (known tracks,
    /// browsers, paused, nothing playing) uses the global tap, so all audio
    /// stays levelled.
    private func desiredTapMode() -> TapMode {
        guard musicOnlyTapViable else { return .global }
        guard playerActive, currentKey != nil, !processor.isKnownTrack else { return .global }
        return musicProcessObject() != nil ? .musicOnly : .global
    }

    /// Switch the tap if the desired mode changed, rebuilding the graph around
    /// the new tap. Idempotent — a no-op when the mode already matches, so it's
    /// safe to call on every track change and play/pause.
    private func applyTapMode() {
        guard isActive else { return }
        let desired = desiredTapMode()
        guard desired != tapMode else { return }
        tapMode = desired
        rebuildGraph(reason: "tap → \(desired == .musicOnly ? "music-only (learning)" : "global")")
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

        if usable, currentTrackIsolated || processor.isKnownTrack {
            // Fold this play's whole-track loudness into the library:
            //  • an unknown track measured in isolation → its clean seed value;
            //  • a known track on the global tap → self-maintenance. A whole-track
            //    integrated reading is robust to brief system sounds (unlike the
            //    live anchor, which the isolated first-learn protects), and
            //    record()'s capped running mean corrects a genuine drift while
            //    one noisy play barely moves an established value.
            library.record(key: key, integratedLUFS: measured, durationMS: currentDurationMS,
                           title: currentTitle, artist: currentArtist, now: now)
            blLog("\(processor.isKnownTrack ? "refined" : "learned") \(key): \(String(format: "%.1f LUFS", measured)) (heard \(Int(coverage * 100))%, \(currentTrackIsolated ? "isolated" : "global"), library=\(library.count))")
        } else if processor.isKnownTrack {
            // Enough heard but no usable measurement — count the play (its "love"
            // grows) and keep the stored level.
            library.recordPlay(key: key, durationMS: currentDurationMS, now: now)
            blLog("played \(key): play counted, level kept (no usable measurement)")
        } else {
            blLog("not learned \(key): unknown track not measured in isolation (\(Int(coverage * 100))%)")
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

        // 1. The tap. Global mode captures everyone but us; music-only mode
        //    (while learning an unknown track) captures just the playing music
        //    app, so its measurement can't be polluted by system sounds — those
        //    play natively, untapped. Never more than one tap on a process at a
        //    time, so an app's audio is never diverted. Mute behaviour is tunable
        //    via `defaults write cc.jorviksoftware.Ballast tapMuteBehavior -int
        //    {0|1|2}` (0 unmuted, 1 muted, 2 muted-when-tapped); default 2.
        let tapDescription: CATapDescription
        if tapMode == .musicOnly, let musicProc = musicProcessObject() {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [musicProc])
            blLog("buildGraph: music-only tap on process \(musicProc)")
        } else {
            if tapMode == .musicOnly {
                // Music process vanished between deciding and building — stay global.
                tapMode = .global
                blLog("buildGraph: music-only requested but no music process — global tap")
            }
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfProcess])
        }
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
            + " frames=\(processor.dbgFrames) gain=\(String(format: "%.2f", processor.meterGainDB))dB srcLoud=\(String(format: "%.1f", processor.meterSourceLoudness))"
            + " tap=\(tapMode == .musicOnly ? "music" : "global") iso=\(currentTrackIsolated) viable=\(musicOnlyTapViable)")
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
        silentSeconds = 0
        lastWatchdogWrites = ring?.dbgWriteCallbacks.load(ordering: .relaxed) ?? 0
        let t = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
        watchdogTimer = t
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        silentSeconds = 0
    }

    private func watchdogTick() {
        guard isActive, let ring else { return }
        // Only judge the graph dead while the player insists a track is playing —
        // a genuine pause/stop legitimately produces silence, as does a browser
        // that simply isn't making sound.
        guard playerActive, isPlaying else { silentSeconds = 0; return }

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

        // Firing but silent: the tap is alive yet delivering nothing though the
        // player says a track is playing. Tolerate real quiet passages, then heal.
        if ring.dbgInputPeak > Self.watchdogSilencePeak {
            silentSeconds = 0
        } else {
            silentSeconds += Self.watchdogInterval
            if silentSeconds >= Self.watchdogHealSeconds {
                heal(reason: "tap silent \(Int(silentSeconds))s while playing (inPeak=\(String(format: "%.4f", ring.dbgInputPeak)))")
            }
        }
    }

    /// Recover from a dead tap. On the global tap, rebuild it — the proven path.
    /// On the music-only tap (the newer, riskier one) don't gamble on a rebuild
    /// that may fail the same way: disable music-only for the rest of the session
    /// and revert to the global tap. This track's learning is forfeited (retried
    /// next play), but audio can never be lost for more than a moment on a
    /// machine where the music-only tap doesn't deliver.
    private func heal(reason: String) {
        silentSeconds = 0
        if tapMode == .musicOnly {
            blLog("watchdog: \(reason) — music-only tap not delivering; disabling it, reverting to global")
            musicOnlyTapViable = false
            tapMode = .global
            currentTrackIsolated = false
            rebuildGraph(reason: "music-only → global (self-heal)")
        } else {
            blLog("watchdog: \(reason) — self-healing (global tap rebuild)")
            rebuildGraph(reason: "global tap rebuild")
        }
    }
}
