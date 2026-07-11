import Foundation

/// One learned track: its measured whole-track loudness and the metadata used
/// to key and validate it.
struct LearnedTrack: Codable {
    var integratedLUFS: Double
    var durationMS: Int
    var plays: Int
    var lastSeen: Double        // seconds since 1970
    var title: String?
    var artist: String?
}

/// A persistent, self-building loudness library keyed by track identity
/// (`am:<PersistentID>` / `sp:<Track ID>` / a title·artist·album composite).
///
/// The more you listen, the more of your music is "known": a known track is
/// levelled from its first sample with a single, dynamics-preserving gain,
/// instead of the live pass having to discover the level as it plays.
@MainActor
final class LoudnessLibrary {

    /// A UID match whose stored duration differs by more than this is treated
    /// as a different recording (remaster, live cut, radio edit).
    private static let durationToleranceMS = 1500

    /// The play-weighted running mean caps its weight here, so a track's learned
    /// loudness never becomes stubborn: past this many plays each fresh reading
    /// keeps a fixed share of influence (an exponential moving average over
    /// roughly the last ~10 plays). That lets the library self-correct a genuine
    /// drift while one noisy play barely moves an established value.
    private static let maintenanceWeightCap = 10

    private var entries: [String: LearnedTrack] = [:]
    private let fileURL: URL
    private var saveScheduled = false

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ballast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        fileURL = dir.appendingPathComponent("library.json")
        load()
    }

    var count: Int { entries.count }

    /// Return the learned loudness for `key`, but only if the duration matches
    /// (guards against title/UID collisions across different recordings).
    func lookup(key: String, durationMS: Int) -> LearnedTrack? {
        guard let entry = entries[key] else { return nil }
        if durationMS > 0, entry.durationMS > 0,
           abs(entry.durationMS - durationMS) > Self.durationToleranceMS {
            return nil
        }
        return entry
    }

    /// Fold a fresh measurement into the library. The first time a track is
    /// heard this seeds its value; every play after refines it as a play-weighted
    /// running mean, so the library keeps itself accurate — a known track is
    /// re-measured (on the global tap) each play and its stored loudness gently
    /// self-corrects toward the truth.
    func record(key: String, integratedLUFS: Double, durationMS: Int,
                title: String?, artist: String?, now: Double) {
        guard integratedLUFS.isFinite else { return }
        if var entry = entries[key],
           abs(entry.durationMS - durationMS) <= Self.durationToleranceMS {
            // Weight the existing value by its play count — but never below 1
            // (else a track whose plays were reset to 0 would be wholly
            // overwritten by one measurement instead of refined) and never above
            // the maintenance cap (so the value stays perpetually self-correcting
            // rather than freezing after many plays).
            let n = Double(min(max(entry.plays, 1), Self.maintenanceWeightCap))
            entry.integratedLUFS = (entry.integratedLUFS * n + integratedLUFS) / (n + 1)
            entry.plays += 1
            entry.lastSeen = now
            if entry.durationMS == 0 { entry.durationMS = durationMS }
            entries[key] = entry
        } else {
            entries[key] = LearnedTrack(integratedLUFS: integratedLUFS, durationMS: durationMS,
                                        plays: 1, lastSeen: now, title: title, artist: artist)
        }
        scheduleSave()
    }

    /// Count a play of an already-known track — advancing its "love" — without
    /// touching the learned loudness. A fallback for when a known play yields no
    /// usable whole-track measurement: the play still counts, the stored value
    /// stands. (A usable play refines the value through `record` instead.)
    func recordPlay(key: String, durationMS: Int, now: Double) {
        guard var entry = entries[key] else { return }
        if durationMS > 0, entry.durationMS > 0,
           abs(entry.durationMS - durationMS) > Self.durationToleranceMS { return }
        entry.plays += 1
        entry.lastSeen = now
        if entry.durationMS == 0 { entry.durationMS = durationMS }
        entries[key] = entry
        scheduleSave()
    }

    /// Play count for a known track (0 if not learned yet).
    func plays(key: String, durationMS: Int) -> Int {
        lookup(key: key, durationMS: durationMS)?.plays ?? 0
    }

    /// Zero every track's play count — and therefore its "love" rating, which
    /// is derived from plays — while keeping the learned loudness, duration and
    /// metadata. Clears the skew from a burst of shuffle-listening during the
    /// learning-in period; levelling is untouched, so known tracks still level
    /// from the first sample.
    func resetPlayStats() {
        for key in entries.keys { entries[key]?.plays = 0 }
        save()
    }

    /// Forget everything — every learned track's loudness, plays and metadata.
    /// A clean slate; the library rebuilds from scratch as you listen again.
    func resetLibrary() {
        entries.removeAll()
        save()
    }

    /// 0...1 percentile rank of this track's play count among all learned
    /// tracks — how "loved" it is versus the rest of the library. nil if the
    /// track isn't known yet.
    func lovePercentile(key: String, durationMS: Int) -> Double? {
        guard let entry = lookup(key: key, durationMS: durationMS) else { return nil }
        let total = entries.count
        guard total > 1 else { return 1 }
        var less = 0, equal = 0
        for e in entries.values {
            if e.plays < entry.plays { less += 1 } else if e.plays == entry.plays { equal += 1 }
        }
        return (Double(less) + Double(equal) * 0.5) / Double(total)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: LearnedTrack].self, from: data) else { return }
        entries = decoded
    }

    /// Coalesce rapid updates into a single write on the next runloop turn.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
