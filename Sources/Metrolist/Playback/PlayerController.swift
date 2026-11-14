import Foundation
import Observation

enum RepeatMode: String, Codable {
    case off, all, one
}

private struct PersistedPlayer: Codable {
    var queue: [Song]
    var index: Int?
    var position: Double
    var repeatMode: RepeatMode
}

/// The playback queue and transport. Owns the audio engine and keeps the system's Now Playing
/// information in sync.
@MainActor
@Observable
final class PlayerController {
    private(set) var queue: [Song] = []
    private(set) var currentIndex: Int?
    /// What the user asked for; the engine may still be loading or buffering.
    private(set) var isPlaying = false
    private(set) var status: AudioEngine.Status = .idle
    /// Coarse position for sliders and labels. Use `currentTime` for frame-accurate sync.
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var shuffle = false
    /// The album, playlist or artist the queue was started from, if any.
    private(set) var sourceId: String?
    var repeatMode: RepeatMode = .off { didSet { persist() } }
    private(set) var lyrics: Lyrics?
    private(set) var lyricsLoading = false
    /// The transition in progress, if AutoMix is blending two tracks right now.
    private(set) var mixActivity: MixEngine.Activity?
    /// Tempo, key and structure of tracks analysed for AutoMix, by video id.
    private(set) var analyses: [String: TrackAnalysis] = [:]
    /// Transitions AutoMix proposes for a pair of songs ("current|next"), best first.
    private(set) var mixCandidates: [String: [MixPlan]] = [:]
    /// Transitions edited by hand, by pair. They take precedence over what AutoMix proposes.
    private(set) var customMixes: [String: MixPlan] = [:]
    var errorMessage: String?
    var sleepTimerEnd: Date?
    var volume: Double {
        didSet {
            engine.volume = Float(volume)
            settings.volume = volume
        }
    }

    /// The level to return to when unmuting.
    @ObservationIgnored private var volumeBeforeMute: Double?

    /// Silences playback, or restores the level it had before it was silenced.
    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute ?? 0.6
            volumeBeforeMute = nil
        }
    }

    @ObservationIgnored let media: MediaStore
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let engine = MixEngine()
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadToken = 0
    /// True when the current song is selected but its audio hasn't been handed to the engine.
    @ObservationIgnored private var needsLoad = false
    @ObservationIgnored private var resumePosition = 0.0
    @ObservationIgnored private var unshuffledQueue: [Song]?
    @ObservationIgnored private var radioContinuation: String?
    @ObservationIgnored private var isExtending = false
    /// Songs Autoplay added, and the order it gave them in. Only these are re-ordered for mixing.
    @ObservationIgnored private var autoQueued: [String: Int] = [:]
    @ObservationIgnored private var autoQueueCounter = 0
    @ObservationIgnored private var sequencedFor = ""
    @ObservationIgnored private var extendBlockedUntil = Date.distantPast
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var counterparts: [String: Song?] = [:]
    @ObservationIgnored private var lyricsRequestedFor: String?
    @ObservationIgnored private var recordedPlayFor: String?
    /// "current|next" pair already handed to the engine for a gapless join.
    @ObservationIgnored private var gaplessKey: String?
    /// Song already reported to the signed-in account's listening history.
    @ObservationIgnored private var reportedPlayFor: String?
    @ObservationIgnored private var analysisRequested: Set<String> = []
    /// Lyrics fetched ahead of time for mix planning (nil: looked for, none found).
    @ObservationIgnored private var mixLyrics: [String: Lyrics?] = [:]
    @ObservationIgnored private var mixLyricsRequested: Set<String> = []
    @ObservationIgnored private var planning: Set<String> = []
    /// Pairs of songs a sample database links, by pair. Observed: finding one re-plans the pair.
    private var sampleRelations: [String: SampleRelation] = [:]
    @ObservationIgnored private var sampleLookups: Set<String> = []

    init(media: MediaStore, library: LibraryStore, settings: AppSettings) {
        self.media = media
        self.library = library
        self.settings = settings
        volume = settings.volume
        engine.volume = Float(settings.volume)

        engine.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.handle(status) }
        }
        engine.onEnded = { [weak self] in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        engine.onAdvanced = { [weak self] videoId in
            MainActor.assumeIsolated { self?.advancedGapless(to: videoId) }
        }
        engine.onActivity = { [weak self] activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Publish in coarse steps so the interface isn't redrawn a hundred times a second.
                if let activity, let current = self.mixActivity, abs(activity.progress - current.progress) < 0.02, activity.progress < 1 { return }
                self.mixActivity = activity
            }
        }
        nowPlaying = NowPlayingBridge(player: self)
        if let data = try? Data(contentsOf: AppPaths.mixes), let saved = try? JSONDecoder().decode([String: MixPlan].self, from: data) {
            // Earlier versions saved a proposal as soon as it was picked to be heard. Those were
            // never edits, so they are dropped; AutoMix chooses afresh for those pairs.
            customMixes = saved.filter { $0.value.preset != .auto }
        }
        restore()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Derived state

    var currentSong: Song? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Frame-accurate playback position, compensated for output latency.
    var currentTime: Double { needsLoad ? resumePosition : engine.currentTime }

    var isBuffering: Bool { isPlaying && (status == .loading || status == .buffering) }

    var hasNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < queue.count || repeatMode == .all
    }

    var upcoming: ArraySlice<Song> {
        guard let currentIndex, currentIndex + 1 < queue.count else { return [] }
        return queue[(currentIndex + 1)...]
    }

    // MARK: - AutoMix

    var nextSong: Song? {
        guard let currentIndex, currentIndex + 1 < queue.count else { return nil }
        return queue[currentIndex + 1]
    }

    /// Consecutive tracks of one album are sequenced by the artist: AutoMix leaves them to
    /// gapless playback unless the listener asked for albums to be mixed as well.
    var isAlbumSequence: Bool {
        guard let album = currentSong?.album?.id else { return false }
        if let next = nextSong { return next.album?.id == album }
        guard let currentIndex, currentIndex > 0 else { return false }
        return queue[currentIndex - 1].album?.id == album
    }

    /// Whether AutoMix can be switched on for what is playing.
    var autoMixAvailable: Bool { settings.mixAlbums || !isAlbumSequence }

    /// AutoMix is on and applies to what is playing.
    var autoMixActive: Bool { settings.autoMix && autoMixAvailable }

    private func mixEligible(_ current: Song, _ next: Song) -> Bool {
        guard repeatMode != .one, !(settings.preferAudioVersions && next.isVideo) else { return false }
        if !settings.mixAlbums, let album = current.album?.id, album == next.album?.id { return false }
        return true
    }

    /// The pair AutoMix would mix next, if there is one.
    var mixPair: (current: Song, next: Song)? {
        guard settings.autoMix, let current = currentSong, let next = nextSong, mixEligible(current, next) else { return nil }
        return (current, next)
    }

    /// A transition being tried out for one pair of songs.
    struct MixAudition {
        var key: String
        var plan: MixPlan
    }

    /// Set while the listener tries a proposal or preset; never saved.
    var mixAudition: MixAudition?

    private func pairKey(_ current: Song, _ next: Song) -> String { "\(current.id)|\(next.id)" }

    private func candidateKey(_ current: Song, _ next: Song) -> String {
        "\(pairKey(current, next))|\(settings.mixLength.rawValue)|\(settings.mixStyle.rawValue)|\(settings.mixKeyMatch)"
            + (sampleRelation(current, next) == nil ? "" : "|sample")
    }

    /// A sampling link between two songs that the database has confirmed, if it has been
    /// looked up and the lookup is switched on.
    private func sampleRelation(_ current: Song, _ next: Song) -> SampleRelation? {
        guard settings.mixSampleLookup else { return nil }
        return sampleRelations[pairKey(current, next)]
    }

    /// True while AutoMix is on but the upcoming pair hasn't been analysed and planned yet.
    var isPreparingMix: Bool {
        guard let pair = mixPair else { return false }
        if customMixes[pairKey(pair.current, pair.next)] != nil { return false }
        return mixCandidates[candidateKey(pair.current, pair.next)] == nil
    }

    /// What AutoMix proposes for the upcoming pair, best first.
    var nextMixCandidates: [MixPlan] {
        guard let pair = mixPair else { return [] }
        return mixCandidates[candidateKey(pair.current, pair.next)] ?? []
    }

    /// The transition that will be used between the current track and the next.
    var nextMixPlan: MixPlan? {
        guard let pair = mixPair else { return nil }
        let key = pairKey(pair.current, pair.next)
        if let trial = mixAudition, trial.key == key { return trial.plan }
        return customMixes[key] ?? mixCandidates[candidateKey(pair.current, pair.next)]?.first
    }

    /// A proposal or preset is being tried out for the upcoming pair without being kept.
    var isAuditioningMix: Bool {
        guard let pair = mixPair, let trial = mixAudition else { return false }
        return trial.key == pairKey(pair.current, pair.next)
    }

    /// A transition has been saved for the upcoming pair.
    var hasSavedMix: Bool {
        guard let pair = mixPair else { return false }
        return customMixes[pairKey(pair.current, pair.next)] != nil
    }

    /// Saves the transition being tried out, so these two songs always use it.
    func keepAuditionedMix() {
        guard let pair = mixPair, let trial = mixAudition, trial.key == pairKey(pair.current, pair.next) else { return }
        var plan = trial.plan
        plan.isCustom = true
        customMixes[trial.key] = plan
        mixAudition = nil
        saveMixes()
    }

    /// Stops trying a transition out and goes back to the saved one, or to AutoMix's choice.
    func endMixAudition() {
        mixAudition = nil
    }

    /// Whether timed lyrics were found for the pair, which lyric matching depends on.
    var mixLyricsNote: String? {
        guard let pair = mixPair else { return nil }
        func timed(_ song: Song) -> Bool? {
            guard let known = mixLyrics[song.id] else { return nil }
            return known?.isSynced == true
        }
        guard let first = timed(pair.current), let second = timed(pair.next) else { return "Looking for lyrics…" }
        switch (first, second) {
        case (true, true): return "Lyrics of both songs were compared for shared lines and for where the singing is"
        case (false, false): return "No timed lyrics for either song, so lyrics couldn't be used"
        default: return "No timed lyrics for “\((first ? pair.next : pair.current).title)”, so lyrics couldn't be compared"
        }
    }

    /// Makes the upcoming transition beat-matched, however far apart the tempos are.
    func beatMatchMix(_ plan: MixPlan) {
        guard let pair = mixPair, let a = analyses[pair.current.id], let b = analyses[pair.next.id] else { return }
        var matched = MixPlanner.beatMatched(plan, a, b, options: settings.mixOptions)
        matched.isCustom = true
        matched.preset = .custom
        matched.reason = .manual
        let lock = abs(matched.periodB / (60 / b.bpm) - 1) > 0.2 && abs(matched.periodB / (60 / b.bpm) - 2) > 0.2 && abs(matched.periodB / (60 / b.bpm) - 0.5) > 0.2
        matched.note = lock
            ? "Beat-matched across a wide tempo gap: the beats lock three against two"
            : "Beat-matched: both songs stretch towards each other across the overlap"
        customMixes[pairKey(pair.current, pair.next)] = MixPlanner.describe(matched, a, b)
        mixAudition = nil
        saveMixes()
    }

    /// Replaces the upcoming transition with a hand-edited one.
    func setCustomMix(_ plan: MixPlan) {
        guard let pair = mixPair, let a = analyses[pair.current.id], let b = analyses[pair.next.id] else { return }
        var plan = MixPlanner.normalized(plan, a, b)
        plan.isCustom = true
        plan = MixPlanner.describe(plan, a, b)
        customMixes[pairKey(pair.current, pair.next)] = plan
        mixAudition = nil
        saveMixes()
    }

    /// Applies one of the stock transitions to the upcoming pair; `.auto` returns it to AutoMix.
    func applyMixPreset(_ preset: MixPreset) {
        guard let pair = mixPair, let a = analyses[pair.current.id], let b = analyses[pair.next.id] else { return }
        let key = pairKey(pair.current, pair.next)
        guard preset != .auto else {
            mixAudition = nil
            customMixes[key] = nil
            saveMixes()
            return
        }
        // Stock moves start from where AutoMix would mix; an existing edit keeps its points.
        let proposals = nextMixCandidates
        let base: MixPlan?
        if let trial = mixAudition, trial.key == key, trial.plan.preset == .auto || trial.plan.preset == .custom {
            base = trial.plan
        } else if let custom = customMixes[key], custom.preset == .custom {
            base = custom
        } else if preset == .blend || preset == .rise || preset == .loop {
            base = proposals.first { $0.sync } ?? proposals.first
        } else {
            base = proposals.first
        }
        guard let base else { return }
        // Tried out, not kept: it applies to this play of the pair unless the listener keeps it.
        mixAudition = MixAudition(key: key, plan: MixPlanner.shaped(base, as: preset, a, b, options: settings.mixOptions))
    }

    /// Uses one of AutoMix's other proposals for the upcoming pair.
    func chooseMixCandidate(_ plan: MixPlan) {
        guard let pair = mixPair else { return }
        let key = pairKey(pair.current, pair.next)
        // Picking a proposal tries it out for this play of the pair; nothing is saved.
        if plan.id == nextMixCandidates.first?.id, customMixes[key] == nil {
            mixAudition = nil
        } else {
            mixAudition = MixAudition(key: key, plan: plan)
        }
    }

    /// Jumps to just before the upcoming transition so it can be heard.
    func previewMix(lead: Double = 5) {
        guard let plan = nextMixPlan else { return }
        // A plan that eases the song to another speed first has to be heard from before that.
        let approach = plan.approach ?? 0
        seek(to: max(0, plan.outStart - approach - (approach > 0 ? min(lead, 3) : lead)))
        if !isPlaying { play() }
    }

    private func saveMixes() {
        let snapshot = customMixes
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: AppPaths.mixes, options: .atomic) }
        }
    }

    /// Adds songs to the end of the queue as Autoplay's choices, which AutoMix may re-order.
    func appendAutoQueued(_ songs: [Song]) {
        for song in songs where autoQueued[song.id] == nil {
            autoQueued[song.id] = autoQueueCounter
            autoQueueCounter += 1
        }
        queue.append(contentsOf: songs)
        unshuffledQueue?.append(contentsOf: songs)
    }

    /// AutoMix is choosing the order of the songs Autoplay lines up.
    private var sequencesAutoQueue: Bool { settings.autoMix && settings.mixOrdersQueue && settings.mixStyle == .smart }

    /// Looks a few Autoplay songs ahead, has them fetched and analysed, and moves the one that
    /// mixes best out of the playing song to the front (`MixSequencer`).
    private func sequenceAutoQueue() {
        guard sequencesAutoQueue, let currentIndex, let current = currentSong else { return }
        let start = currentIndex + 1
        var end = start
        while end < queue.count, end - start < MixSequencer.pool, autoQueued[queue[end].id] != nil { end += 1 }
        guard end - start >= 2 else { return }
        let pool = Array(queue[start ..< end])
        // Fetch them one at a time, so looking ahead never crowds out what is playing.
        if position > 3, !pool.contains(where: { media.isFetching($0.id) }),
           let missing = pool.first(where: { media.records[$0.id] == nil && !media.failed.contains($0.id) }) {
            media.prefetch(videoId: missing.id)
        }
        for song in pool where analyses[song.id] == nil && !analysisRequested.contains(song.id) {
            guard let record = media.records[song.id] else { continue }
            analysisRequested.insert(song.id)
            let file = AppPaths.media.appendingPathComponent(record.fileName)
            Task {
                if let analysis = await TrackAnalyzer.shared.analysis(videoId: song.id, file: file) { analyses[song.id] = analysis }
            }
        }
        guard let a = analyses[current.id] else { return }
        // Leave the next song alone once its transition is under way or about to be, or
        // when the listener has chosen how these two are mixed.
        if mixActivity != nil || (duration > 0 && position > duration - 30) { return }
        if let plan = nextMixPlan, position > plan.outStart - (plan.approach ?? 0) - 20 { return }
        if customMixes[pairKey(current, pool[0])] != nil || mixAudition != nil { return }
        let known = pool.filter { analyses[$0.id] != nil }.map(\.id).sorted()
        let signature = "\(current.id)|\(pool.map(\.id).sorted().joined(separator: ","))|\(known.joined(separator: ","))"
        guard signature != sequencedFor, !known.isEmpty else { return }
        sequencedFor = signature
        let ordered = MixSequencer.order(after: current, a, pool: pool.map { ($0, analyses[$0.id], autoQueued[$0.id] ?? 0) }, keyMatch: settings.mixKeyMatch)
        guard ordered.map(\.item.id) != pool.map(\.id) else { return }
        queue.replaceSubrange(start ..< end, with: ordered.map(\.item))
        if let first = ordered.first {
            MixLog.write("autoplay order: \(first.item.title) moved up to follow \(current.title)\(first.fit.map { " (\($0.note))" } ?? "")")
        }
        persist()
    }

    /// Fetches, analyses and plans the current and next tracks in the background.
    private func prepareMix() {
        sequenceAutoQueue()
        guard settings.autoMix, let current = currentSong else { return }
        let next = nextSong.flatMap { mixEligible(current, $0) ? $0 : nil }
        // A transition that was only being tried out does not outlive its pair of songs.
        if let trial = mixAudition, trial.key != next.map({ pairKey(current, $0) }) { mixAudition = nil }
        if let next, position > 3 { media.prefetch(videoId: next.id) }
        for song in [current, next].compactMap({ $0 }) where analyses[song.id] == nil && !analysisRequested.contains(song.id) {
            guard let record = media.records[song.id] else { continue }
            analysisRequested.insert(song.id)
            let file = AppPaths.media.appendingPathComponent(record.fileName)
            Task {
                if let analysis = await TrackAnalyzer.shared.analysis(videoId: song.id, file: file) {
                    analyses[song.id] = analysis
                }
            }
        }
        guard let next else { return }
        // Lyrics tell the planner where the singing is and which words the two songs share.
        if let lyrics, lyricsRequestedFor == current.id, mixLyrics[current.id] == nil { mixLyrics[current.id] = .some(lyrics) }
        for song in [current, next] where mixLyrics[song.id] == nil && !mixLyricsRequested.contains(song.id) {
            mixLyricsRequested.insert(song.id)
            Task {
                var found = await LyricsService.shared.cached(song.id)
                if found == nil { found = await LyricsService.shared.fetch(for: song, duration: Double(song.duration ?? 0)) }
                if mixLyrics[song.id] == nil { mixLyrics[song.id] = .some(found) }
            }
        }
        // Ask, in the background, whether one of the two is known to sample the other. Planning
        // does not wait for the answer: the pair is planned again if a link turns up.
        let pair = pairKey(current, next)
        if settings.mixSampleLookup, settings.mixStyle == .smart, !sampleLookups.contains(pair) {
            sampleLookups.insert(pair)
            Task {
                guard let found = await SampleDatabase.shared.relation(current: current, next: next) else { return }
                // Too late to change course if this pair's transition is about to start.
                if currentSong?.id == current.id, let planned = nextMixPlan, mixActivity != nil || position > planned.outStart - (planned.approach ?? 0) - 20 { return }
                sampleRelations[pair] = found
                prepareMix()
            }
        }
        let key = candidateKey(current, next)
        guard mixCandidates[key] == nil, !planning.contains(key),
              let a = analyses[current.id], let b = analyses[next.id],
              let lyricsA = mixLyrics[current.id], let lyricsB = mixLyrics[next.id]
        else { return }
        planning.insert(key)
        var options = settings.mixOptions
        options.relation = sampleRelation(current, next)
        Task {
            let plans = await Task.detached(priority: .userInitiated) {
                MixPlanner.candidates(from: a, to: b, lyricsA: lyricsA, lyricsB: lyricsB, options: options)
            }.value
            mixCandidates[key] = plans
            planning.remove(key)
        }
    }

    // MARK: - Starting playback

    /// Replaces the queue and starts playing at `index`.
    func play(_ songs: [Song], startAt index: Int = 0, shuffled: Bool = false, source: String? = nil) {
        guard !songs.isEmpty else { return }
        sourceId = source
        var songs = songs
        var index = min(max(0, index), songs.count - 1)
        unshuffledQueue = nil
        shuffle = shuffled
        if shuffled {
            unshuffledQueue = songs
            let first = songs.remove(at: index)
            songs.shuffle()
            songs.insert(first, at: 0)
            index = 0
        }
        queue = songs
        radioContinuation = nil
        library.remember(songs)
        start(index: index)
    }

    /// Plays one song and lets YouTube Music's radio fill the queue behind it.
    func play(song: Song) {
        play([song])
    }

    func playRadio(for song: Song) {
        play([song])
    }

    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        library.remember(songs)
        guard let currentIndex else {
            play(songs)
            return
        }
        queue.insert(contentsOf: songs, at: currentIndex + 1)
        persist()
    }

    func enqueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        library.remember(songs)
        guard currentIndex != nil else {
            play(songs)
            return
        }
        queue.append(contentsOf: songs)
        persist()
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        start(index: index)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        queue.remove(at: index)
        if let currentIndex, index < currentIndex { self.currentIndex = currentIndex - 1 }
        persist()
    }

    func moveInQueue(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), destination >= 0, destination <= queue.count, source != destination else { return }
        let current = currentSong
        let song = queue.remove(at: source)
        queue.insert(song, at: destination > source ? destination - 1 : destination)
        if let current { currentIndex = queue.firstIndex(of: current) }
        persist()
    }

    func clearUpcoming() {
        guard let currentIndex, currentIndex + 1 < queue.count else { return }
        queue.removeSubrange((currentIndex + 1)...)
        radioContinuation = nil
        persist()
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard currentSong != nil else { return }
        isPlaying = true
        if needsLoad {
            loadCurrent(at: resumePosition)
        } else if case .failed = status {
            loadCurrent(at: position)
        } else {
            engine.play()
        }
        publishNowPlaying()
    }

    func pause() {
        isPlaying = false
        engine.pause()
        position = currentTime
        publishNowPlaying()
        persist()
    }

    func next() {
        guard let currentIndex else { return }
        if currentIndex + 1 < queue.count {
            start(index: currentIndex + 1)
        } else if repeatMode == .all {
            start(index: 0)
        }
    }

    func previous() {
        guard let currentIndex else { return }
        if currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
        } else {
            start(index: currentIndex - 1)
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        position = target
        if needsLoad {
            resumePosition = target
        } else {
            engine.seek(to: target)
        }
        publishNowPlaying()
    }

    func toggleShuffle() {
        guard let currentIndex else {
            shuffle.toggle()
            return
        }
        let current = queue[currentIndex]
        if shuffle {
            shuffle = false
            if let original = unshuffledQueue, let index = original.firstIndex(of: current) {
                queue = original
                self.currentIndex = index
            }
            unshuffledQueue = nil
        } else {
            shuffle = true
            unshuffledQueue = queue
            var rest = queue
            rest.remove(at: currentIndex)
            rest.shuffle()
            queue = [current] + rest
            self.currentIndex = 0
        }
        persist()
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func toggleLikeCurrent() {
        guard let currentSong else { return }
        library.toggleLike(currentSong)
        publishNowPlaying()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimerEnd = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
    }

    func adjustLyricsOffset(by delta: Double) {
        guard var current = lyrics, let song = currentSong else { return }
        current.offset = delta == 0 ? 0 : ((current.offset + delta) * 10).rounded() / 10
        lyrics = current
        Task { await LyricsService.shared.setOffset(current.offset, for: song.id) }
    }

    func reloadLyrics() {
        guard let song = currentSong else { return }
        fetchLyrics(for: song, forceRefresh: true)
    }

    // MARK: - Loading

    private func start(index: Int) {
        currentIndex = index
        isPlaying = true
        errorMessage = nil
        loadCurrent(at: 0)
        extendQueueIfNeeded()
    }

    private func loadCurrent(at startPosition: Double) {
        guard let index = currentIndex, queue.indices.contains(index) else { return }
        loadToken += 1
        let token = loadToken
        let song = queue[index]
        needsLoad = false
        position = startPosition
        duration = Double(song.duration ?? 0)
        status = .loading
        lyrics = nil
        lyricsRequestedFor = nil
        recordedPlayFor = nil
        gaplessKey = nil
        publishNowPlaying()
        persist()

        Task {
            var song = song
            if settings.preferAudioVersions, song.isVideo, !media.isAvailableOffline(song.id) {
                if let audio = await audioVersion(of: song), token == loadToken,
                   let index = currentIndex, queue.indices.contains(index), queue[index].id == song.id {
                    queue[index] = audio
                    library.remember([audio])
                    song = audio
                    if duration == 0 { duration = Double(audio.duration ?? 0) }
                    publishNowPlaying()
                }
            }
            guard token == loadToken else { return }
            if let cached = await LyricsService.shared.cached(song.id), token == loadToken {
                lyrics = cached
                lyricsRequestedFor = song.id
            }
            media.protectedId = song.id
            let opened = media.open(videoId: song.id)
            // A track that may be mixed out of goes through the time-stretcher from the start,
            // so its tempo can glide during the transition without a break in the sound.
            engine.load(opened, startAt: startPosition, autoplay: isPlaying, normalize: settings.normalizeVolume, mixReady: autoMixActive)
        }
    }

    private func audioVersion(of song: Song) async -> Song? {
        if let known = counterparts[song.id] { return known }
        let found = await YTMusic.audioCounterpart(for: song)
        counterparts[song.id] = .some(found)
        return found
    }

    private func fetchLyrics(for song: Song, forceRefresh: Bool = false) {
        lyricsRequestedFor = song.id
        lyricsLoading = true
        let length = duration
        Task {
            let result = await LyricsService.shared.fetch(for: song, duration: length, forceRefresh: forceRefresh)
            guard currentSong?.id == song.id else { return }
            lyrics = result
            lyricsLoading = false
        }
    }

    // MARK: - Engine events

    private func handle(_ newStatus: AudioEngine.Status) {
        status = newStatus
        switch newStatus {
        case .ready:
            consecutiveFailures = 0
            if engine.duration > 0 { duration = engine.duration }
            if let song = currentSong {
                if lyricsRequestedFor != song.id { fetchLyrics(for: song) }
                if isPlaying, recordedPlayFor != song.id {
                    recordedPlayFor = song.id
                    library.recordPlay(song)
                }
            }
            publishNowPlaying()
        case .failed(let message):
            consecutiveFailures += 1
            errorMessage = message
            skipAfterFailure()
        default:
            break
        }
    }

    private func skipAfterFailure() {
        guard let currentIndex, isPlaying else { return }
        // While YouTube is bot-checking this connection only songs already on disk can play;
        // asking for more streams would only keep the block alive.
        let offline = !NetworkStatus.shared.isOnline || errorMessage == YTError.botCheckMessage
        let candidates = queue.indices.filter { $0 > currentIndex }
        let nextIndex = offline
            ? candidates.first { media.isAvailableOffline(queue[$0].id) }
            : (consecutiveFailures < 3 ? candidates.first : nil)
        if let nextIndex {
            start(index: nextIndex)
        } else {
            isPlaying = false
            publishNowPlaying()
        }
    }

    /// The engine flowed into the next track on its own; bring the rest of the app along.
    private func advancedGapless(to videoId: String) {
        guard let currentIndex, currentIndex + 1 < queue.count, queue[currentIndex + 1].id == videoId else { return }
        loadToken += 1
        let song = queue[currentIndex + 1]
        self.currentIndex = currentIndex + 1
        gaplessKey = nil
        position = 0
        duration = engine.duration > 0 ? engine.duration : Double(song.duration ?? 0)
        lyrics = nil
        lyricsRequestedFor = nil
        media.protectedId = song.id
        recordedPlayFor = song.id
        library.recordPlay(song)
        fetchLyrics(for: song)
        publishNowPlaying()
        persist()
        extendQueueIfNeeded()
    }

    private func trackEnded() {
        guard let currentIndex else { return }
        if repeatMode == .one {
            engine.seek(to: 0)
            engine.play()
            position = 0
            publishNowPlaying()
            return
        }
        if currentIndex + 1 < queue.count {
            start(index: currentIndex + 1)
        } else if repeatMode == .all {
            start(index: 0)
        } else {
            isPlaying = false
            position = duration
            publishNowPlaying()
        }
    }

    private func tick() {
        guard currentSong != nil else { return }
        if !needsLoad {
            let time = engine.currentTime
            if abs(time - position) > 0.05 { position = time }
            let length = engine.duration
            if length > 0, abs(length - duration) > 0.05 { duration = length }
        }
        if let end = sleepTimerEnd, Date() >= end {
            sleepTimerEnd = nil
            pause()
        }
        guard isPlaying, let currentIndex else { return }
        // Once a song has really been listened to, add it to the account's history.
        let playing = queue[currentIndex]
        // Once per listen, like the official clients.
        if position > 30 || (duration > 0 && position > duration * 0.5), reportedPlayFor != playing.id, InnerTube.shared.isSignedIn {
            reportedPlayFor = playing.id
            Task { try? await YTMusic.reportPlayback(videoId: playing.id) }
        }
        prepareMix()
        // Hand the next track to the engine ahead of time: with a mix plan it is cued for a
        // DJ-style transition, otherwise it follows without a gap.
        var key: String?
        var plan: MixPlan?
        if currentIndex + 1 < queue.count, repeatMode != .one {
            let upcoming = queue[currentIndex + 1]
            if !(settings.preferAudioVersions && upcoming.isVideo) {
                let pair = "\(queue[currentIndex].id)|\(upcoming.id)"
                // The plan's signature is part of the key, so an edit re-cues the transition.
                if let mix = nextMixPlan, position < mix.outStart - 0.5 || gaplessKey == pair + "|mix|\(mix.signature)" {
                    if position >= mix.outStart - 30 - (mix.approach ?? 0) {
                        key = pair + "|mix|\(mix.signature)"
                        plan = mix
                    }
                } else if duration > 0, duration - position < 30 {
                    key = pair
                }
            }
        }
        if key != gaplessKey {
            gaplessKey = key
            engine.enqueueNext(key == nil ? nil : media.open(videoId: queue[currentIndex + 1].id), plan: plan, normalize: settings.normalizeVolume)
        }
        extendQueueIfNeeded()
    }

    /// Appends radio tracks when the queue is about to run out.
    private func extendQueueIfNeeded() {
        guard settings.autoplay, !isExtending, repeatMode == .off,
              // With AutoMix choosing the order, keep enough lined up to choose between.
              let currentIndex, queue.count - currentIndex <= (sequencesAutoQueue ? MixSequencer.pool + 1 : 2), let seed = queue.last,
              NetworkStatus.shared.isOnline, Date() >= extendBlockedUntil
        else { return }
        isExtending = true
        let continuation = radioContinuation
        Task {
            defer { isExtending = false }
            let page: QueuePage?
            if let continuation {
                page = try? await YTMusic.queue(continuation: continuation)
            } else {
                page = try? await YTMusic.radio(for: seed.id)
            }
            guard let page else {
                extendBlockedUntil = Date().addingTimeInterval(30)
                return
            }
            let existing = Set(queue.map(\.id))
            let fresh = page.songs.filter { !existing.contains($0.id) }
            appendAutoQueued(fresh)
            radioContinuation = page.continuation
            library.remember(fresh)
            // Stop asking when the radio has nothing new, to avoid a request loop.
            if fresh.isEmpty {
                radioContinuation = nil
                extendBlockedUntil = Date().addingTimeInterval(120)
            }
            persist()
        }
    }

    // MARK: - Now Playing & persistence

    private func publishNowPlaying() {
        let song = currentSong
        nowPlaying?.update(
            song: song,
            isPlaying: isPlaying,
            position: position,
            duration: duration,
            liked: song.map { library.isLiked($0.id) } ?? false
        )
    }

    private func persist() {
        let snapshot = PersistedPlayer(queue: queue, index: currentIndex, position: currentTime, repeatMode: repeatMode)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: AppPaths.playerState, options: .atomic)
            }
        }
    }

    func saveState() {
        let snapshot = PersistedPlayer(queue: queue, index: currentIndex, position: currentTime, repeatMode: repeatMode)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: AppPaths.playerState, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: AppPaths.playerState),
              let saved = try? JSONDecoder().decode(PersistedPlayer.self, from: data),
              let index = saved.index, saved.queue.indices.contains(index)
        else { return }
        queue = saved.queue
        currentIndex = index
        repeatMode = saved.repeatMode
        resumePosition = saved.position
        position = saved.position
        duration = Double(saved.queue[index].duration ?? 0)
        needsLoad = true
        let song = saved.queue[index]
        Task {
            if let cached = await LyricsService.shared.cached(song.id), currentSong?.id == song.id, lyrics == nil {
                lyrics = cached
                lyricsRequestedFor = song.id
            }
        }
        publishNowPlaying()
    }
}
