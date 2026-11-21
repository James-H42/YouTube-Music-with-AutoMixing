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
    /// The album being played as a whole, if the queue was started from one. Autoplay adds
    /// nothing after it, so an album ends where its artist ended it.
    private(set) var playingAlbumId: String?
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
    /// Set while the queue is a radio the listener started (Start Radio). A radio fills the
    /// queue at once and keeps going whatever the Autoplay setting says, as in YouTube Music.
    private(set) var radioSeed: String?
    /// Counts replacements of the whole queue, so a radio or Autoplay page asked for the queue
    /// before is never added to the one after it.
    @ObservationIgnored private var queueGeneration = 0
    /// The queue generation an Autoplay or radio request is out for, if one is.
    @ObservationIgnored private var extendingGeneration: Int?
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
    /// When the current listen began, how long it has really been played, and whether it was scrobbled.
    @ObservationIgnored private var listenStartedAt = Date()
    @ObservationIgnored private var listenPlayed = 0.0
    @ObservationIgnored private var scrobbledFor: String?
    @ObservationIgnored private var analysisRequested: Set<String> = []
    /// Lyrics fetched ahead of time for mix planning (nil: looked for, none found).
    @ObservationIgnored private var mixLyrics: [String: Lyrics?] = [:]
    @ObservationIgnored private var mixLyricsRequested: Set<String> = []
    @ObservationIgnored private var planning: Set<String> = []
    /// Counts changes to lyrics, so a plan made from older lyrics is thrown away.
    @ObservationIgnored private var lyricsEpoch = 0
    /// Pairs of songs a sample database links, by pair. Observed: finding one re-plans the pair.
    private var sampleRelations: [String: SampleRelation] = [:]
    @ObservationIgnored private var sampleLookups: Set<String> = []

    init(media: MediaStore, library: LibraryStore, settings: AppSettings) {
        self.media = media
        self.library = library
        self.settings = settings
        volume = settings.volume
        engine.volume = Float(settings.volume)
        // Core ML compiles the stem model for the GPU on first use (about 20 s); do that now so
        // the first transition has its stems in time.
        if settings.autoMix, settings.mixStems { StemSeparator.warmUp() }

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
        // Discord asks for the playing song when its setting is switched on mid-song.
        DiscordPresence.shared.currentState = { [weak self] in
            guard let self else { return nil }
            return (self.currentSong, self.isPlaying, self.position, self.duration)
        }
        // Play through the output chosen last time, and follow later choices.
        engine.setOutputDevice(OutputDevices.shared.selectedID)
        OutputDevices.shared.onChange = { [weak self] id in self?.engine.setOutputDevice(id) }
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

    /// A video next in the queue may still be swapped for its audio release when it starts
    /// (Settings → "Prefer audio versions"). Until the lookup has answered, nobody knows which
    /// recording will play, so it can't be analysed yet. Once it has, the pair is planned against
    /// whatever will really play: the audio release, or the video's own audio when there is none.
    private func awaitingAudioVersion(_ song: Song) -> Bool {
        swapsForAudio(song) && counterparts[song.id] == nil
    }

    /// Videos the listener started themselves (a live performance or music video clicked on
    /// an artist page, in search…). They play as videos, picture included; only videos that
    /// arrive on their own (playlists, radio, Autoplay) are swapped for their audio release.
    @ObservationIgnored private(set) var chosenVideos: Set<String> = []
    /// Called when the listener starts a video themselves.
    @ObservationIgnored var onChosenVideo: (() -> Void)?

    /// Whether a video is replaced by its audio release when it plays.
    private func swapsForAudio(_ song: Song) -> Bool {
        settings.preferAudioVersions && song.isVideo && !media.isAvailableOffline(song.id) && !chosenVideos.contains(song.id)
    }

    /// A music video or live performance playing as itself (not swapped for its audio release)
    /// is never mixed into or out of: its picture would jump, and the switch between video and
    /// cover doesn't change that. A video still in the queue is swapped (or not) before this is
    /// asked, so a music video here is one that will really play. Uploads that stand in for
    /// songs (`isVideo` but not `isMusicVideo`) mix like songs.
    private func playsAsVideo(_ song: Song) -> Bool { song.isMusicVideo }

    /// A music video is playing as itself: Autoplay then lines up only music videos, and
    /// music videos queued behind it play as videos too.
    /// Only a video the listener started themselves counts: one that turned up in a playlist
    /// without an audio release plays as itself, but doesn't turn what follows into videos.
    var isVideoSession: Bool {
        guard let song = currentSong, song.isMusicVideo else { return false }
        return chosenVideos.contains(song.id)
    }

    /// Music videos queued during a video session play as videos, not as their audio release.
    private func adoptVideos(_ songs: [Song]) {
        guard isVideoSession else { return }
        chosenVideos.formUnion(songs.filter(\.isMusicVideo).map(\.id))
    }

    private func mixEligible(_ current: Song, _ next: Song) -> Bool {
        guard repeatMode != .one, !awaitingAudioVersion(next) else { return false }
        if playsAsVideo(current) || playsAsVideo(next) { return false }
        if !settings.mixAlbums, let album = current.album?.id, album == next.album?.id { return false }
        return true
    }

    /// Why there is no transition to show for the next track (for the queue's transition row).
    var mixSkipReason: String {
        guard let current = currentSong, let next = nextSong else { return "Nothing queued to mix into" }
        if repeatMode == .one { return "Repeats this song" }
        if awaitingAudioVersion(next) { return "Looking for the audio version of the next track…" }
        if playsAsVideo(current) || playsAsVideo(next) { return "Plays straight through (music videos aren't mixed)" }
        if !settings.mixAlbums, let album = current.album?.id, album == next.album?.id { return "Plays straight through (same album)" }
        return "Plays straight through"
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
        "\(pairKey(current, next))|\(settings.mixLength.rawValue)|\(settings.mixStyle.rawValue)|\(settings.mixKeyMatch)|\(settings.mixStems)"
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
        return customMixes[key] ?? lateChoice[key] ?? mixCandidates[candidateKey(pair.current, pair.next)]?.first
    }

    // MARK: - Play Next

    /// Songs chosen with Play Next (by id). While they wait directly after the playing song,
    /// nothing re-orders them: AutoMix's Autoplay ordering, shuffle and shared-queue guests all
    /// work behind them.
    @ObservationIgnored private var playNextIds: Set<String> = []
    /// For one play of a pair: the transition chosen because the best one could no longer be
    /// reached when the next song was decided (a late Play Next). Never saved.
    @ObservationIgnored private var lateChoice: [String: MixPlan] = [:]
    @ObservationIgnored private var choiceChecked: Set<String> = []

    /// The next song when a transition into it is already audible (before the hand-over).
    private var audibleIncomingIndex: Int? {
        guard mixActivity != nil, let currentIndex, currentIndex + 1 < queue.count,
              gaplessKey?.hasPrefix("\(queue[currentIndex].id)|\(queue[currentIndex + 1].id)|mix") == true else { return nil }
        return currentIndex + 1
    }

    /// Where Play Next puts songs: straight after the playing song, or after the one already
    /// fading in, which can't be taken back.
    var playNextIndex: Int { (audibleIncomingIndex ?? currentIndex ?? -1) + 1 }

    /// The first upcoming place that may be re-ordered or inserted before: after a song already
    /// fading in and after the Play Next songs waiting at the front.
    var firstFlexibleIndex: Int {
        guard currentIndex != nil else { return 0 }
        var index = playNextIndex
        while index < queue.count, playNextIds.contains(queue[index].id) { index += 1 }
        return index
    }

    func isPlayNext(_ id: String) -> Bool { playNextIds.contains(id) }

    /// The listener (or their own phone) queued these: Autoplay's mark goes, so AutoMix never
    /// moves them, and Play Next songs are held at the front.
    func markQueuedByHand(_ ids: [String], playNext: Bool) {
        for id in ids {
            autoQueued[id] = nil
            if playNext { playNextIds.insert(id) }
        }
    }

    /// Once the next song is known, makes sure the transition into it can still happen: if the
    /// best one's mix point (or the tempo approach before it) has already gone by, the best one
    /// still ahead is used for this play instead. Checked once per pair and play, so seeking
    /// never switches transitions, and the ranking itself is untouched.
    private func chooseReachablePlan(_ current: Song, _ next: Song) {
        let key = pairKey(current, next)
        guard !choiceChecked.contains(key), customMixes[key] == nil, mixAudition == nil,
              let plans = mixCandidates[candidateKey(current, next)], let best = plans.first, currentSong?.id == current.id
        else { return }
        choiceChecked.insert(key)
        let now = position
        func reachable(_ plan: MixPlan) -> Bool { plan.outStart - (plan.approach ?? 0) > now + 2 }
        guard !reachable(best) else { return }
        let chosen = plans.first(where: reachable) ?? plans.first { $0.approach == nil && $0.outStart > now + 4 }
        if let chosen {
            lateChoice[key] = chosen
            MixLog.write(String(format: "next track decided at %.1f s, after %@ could start; using %@ (out at %.2f s)", now, best.summary, chosen.summary, chosen.outStart))
        } else {
            MixLog.write(String(format: "next track decided at %.1f s; no transition can still be reached, it follows without one", now))
        }
    }

    /// A song has become the playing one: it no longer waits, and per-play choices reset.
    private func becameCurrent(_ song: Song) {
        playNextIds.remove(song.id)
        lateChoice = [:]
        choiceChecked = []
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
        // Stems still being separated need about 8 s (separating, then the 3 s a deck reads
        // ahead) to be in place for the whole overlap; start the preview earlier until they are.
        var lead = lead
        if settings.mixStems, MixEngine.usesStems(plan), !stemsSeparated(for: plan) { lead = max(lead, 10) }
        // A plan that eases the song to another speed first has to be heard from before that.
        let approach = plan.approach ?? 0
        seek(to: max(0, plan.outStart - approach - (approach > 0 ? min(lead, 3) : lead)))
        if !isPlaying { play() }
    }

    /// Reads the saved transitions again, after a restore replaced the file.
    func reloadSavedMixes() {
        mixAudition = nil
        customMixes = [:]
        if let data = try? Data(contentsOf: AppPaths.mixes), let saved = try? JSONDecoder().decode([String: MixPlan].self, from: data) {
            customMixes = saved.filter { $0.value.preset != .auto }
        }
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

    /// Whether Autoplay (rather than a person) put this song in the queue.
    func isAutoQueued(_ id: String) -> Bool { autoQueued[id] != nil }

    /// AutoMix is choosing the order of the songs Autoplay lines up.
    private var sequencesAutoQueue: Bool { settings.autoMix && settings.mixOrdersQueue && settings.mixStyle == .smart }

    /// Looks a few Autoplay songs ahead, has them fetched and analysed, and moves the one that
    /// mixes best out of the song before them to the front (`MixSequencer`).
    private func sequenceAutoQueue() {
        // Videos aren't mixed, so there is no order to choose for mixing.
        guard sequencesAutoQueue, !isVideoSession, let currentIndex, currentSong != nil else { return }
        // Play Next songs (and one already fading in) keep their places at the front. Autoplay's
        // songs after them are ordered to follow the last of them, the song they will mix out of.
        let start = firstFlexibleIndex
        guard start > currentIndex, start <= queue.count else { return }
        let anchor = queue[start - 1]
        var end = start
        while end < queue.count, end - start < MixSequencer.pool, autoQueued[queue[end].id] != nil { end += 1 }
        guard end - start >= 2 else { return }
        let pool = Array(queue[start ..< end])
        // Fetch them one at a time, so looking ahead never crowds out what is playing. The song
        // they follow comes first when it isn't the playing one (a Play Next song).
        let wanted = (start > currentIndex + 1 ? [anchor] : []) + pool
        if position > 3, !wanted.contains(where: { media.isFetching($0.id) }),
           let missing = wanted.first(where: { media.records[$0.id] == nil && !media.failed.contains($0.id) }) {
            media.prefetch(videoId: missing.id)
        }
        for song in [anchor] + pool where analyses[song.id] == nil && !analysisRequested.contains(song.id) {
            guard let record = media.records[song.id] else { continue }
            analysisRequested.insert(song.id)
            let file = AppPaths.media.appendingPathComponent(record.fileName)
            Task {
                if let analysis = await TrackAnalyzer.shared.analysis(videoId: song.id, file: file) { analyses[song.id] = analysis }
            }
        }
        guard let a = analyses[anchor.id] else { return }
        // When the first of them is the next song, leave it alone once its transition is under
        // way or about to be. Either way, not when the listener has chosen how they are mixed.
        if start == currentIndex + 1 {
            if mixActivity != nil || (duration > 0 && position > duration - 30) { return }
            if let plan = nextMixPlan, position > plan.outStart - (plan.approach ?? 0) - 20 { return }
            if mixAudition != nil { return }
        }
        if customMixes[pairKey(anchor, pool[0])] != nil { return }
        let known = pool.filter { analyses[$0.id] != nil }.map(\.id).sorted()
        let signature = "\(anchor.id)|\(pool.map(\.id).sorted().joined(separator: ","))|\(known.joined(separator: ","))"
        guard signature != sequencedFor, !known.isEmpty else { return }
        sequencedFor = signature
        let ordered = MixSequencer.order(after: anchor, a, pool: pool.map { ($0, analyses[$0.id], autoQueued[$0.id] ?? 0) }, keyMatch: settings.mixKeyMatch)
        guard ordered.map(\.item.id) != pool.map(\.id) else { return }
        queue.replaceSubrange(start ..< end, with: ordered.map(\.item))
        if let first = ordered.first {
            MixLog.write("autoplay order: \(first.item.title) moved up to follow \(anchor.title)\(first.fit.map { " (\($0.note))" } ?? "")")
        }
        persist()
    }

    /// Fetches, analyses and plans the current and next tracks in the background.
    private func prepareMix() {
        sequenceAutoQueue()
        guard settings.autoMix, let current = currentSong else { return }
        resolveNextAudioVersion()
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
        chooseReachablePlan(current, next)
        guard mixCandidates[key] == nil, !planning.contains(key),
              let a = analyses[current.id], let b = analyses[next.id],
              let lyricsA = mixLyrics[current.id], let lyricsB = mixLyrics[next.id]
        else { return }
        planning.insert(key)
        let epoch = lyricsEpoch
        var options = settings.mixOptions
        options.relation = sampleRelation(current, next)
        Task {
            let plans = await Task.detached(priority: .userInitiated) {
                MixPlanner.candidates(from: a, to: b, lyricsA: lyricsA, lyricsB: lyricsB, options: options)
            }.value
            planning.remove(key)
            if epoch == lyricsEpoch {
                mixCandidates[key] = plans
                chooseReachablePlan(current, next)
            }
        }
    }

    @ObservationIgnored private var resolvingAudio: Set<String> = []

    /// Brings the queue's copies of songs up to date with their newly learned video types.
    func applyVideoTypes(_ types: [String: String]) {
        func update(_ songs: inout [Song]) {
            for index in songs.indices {
                guard let type = types[songs[index].id], !type.isEmpty, songs[index].videoType != type else { continue }
                songs[index].videoType = type
                songs[index].isVideo = Parser.isVideoType(type)
            }
        }
        update(&queue)
        if var original = unshuffledQueue {
            update(&original)
            unshuffledQueue = original
        }
        persist()
    }

    /// Tests: what the audio-release lookup will answer for a video, without the network.
    func setAudioVersionForTesting(_ videoId: String, _ audio: Song?) { counterparts[videoId] = .some(audio) }

    /// Does ahead of time what `loadCurrent` does when a video starts: finds its audio release
    /// and puts it in the queue, so AutoMix analyses and plans against what will really play.
    private func resolveNextAudioVersion() {
        guard let currentIndex, currentIndex + 1 < queue.count else { return }
        let next = queue[currentIndex + 1]
        guard swapsForAudio(next) else { return }
        if let known = counterparts[next.id] {
            if let audio = known { replaceUpcoming(next, with: audio) }
            return
        }
        guard !resolvingAudio.contains(next.id) else { return }
        resolvingAudio.insert(next.id)
        Task {
            _ = await audioVersion(of: next)
            resolvingAudio.remove(next.id)
            prepareMix()
        }
    }

    private func replaceUpcoming(_ video: Song, with audio: Song) {
        guard let currentIndex, currentIndex + 1 < queue.count, queue[currentIndex + 1].id == video.id else { return }
        queue[currentIndex + 1] = audio
        if let index = unshuffledQueue?.firstIndex(where: { $0.id == video.id }) { unshuffledQueue?[index] = audio }
        if let order = autoQueued[video.id] { autoQueued[audio.id] = order }
        library.remember([audio])
        MixLog.write("next track: \(video.title) is a video; its audio release \(audio.title) [\(audio.id)] will play and is mixed into")
        persist()
    }

    // MARK: - Starting playback

    /// Replaces the queue and starts playing at `index`.
    /// `chosen`: the listener picked the starting song itself (clicked its row), so a video
    /// there plays as a video.
    func play(_ songs: [Song], startAt index: Int = 0, shuffled: Bool = false, source: String? = nil, chosen: Bool = false) {
        // Songs YouTube Music greys out can't be played; leave them out of the queue.
        var index = index
        var songs = songs
        if songs.contains(where: { $0.unavailable == true }) {
            let target = songs.indices.contains(index) ? songs[index].id : nil
            songs.removeAll { $0.unavailable == true }
            index = target.flatMap { id in songs.firstIndex { $0.id == id } } ?? min(index, max(0, songs.count - 1))
        }
        guard !songs.isEmpty else { return }
        if chosen, !shuffled, songs.indices.contains(index), songs[index].isMusicVideo {
            chosenVideos.insert(songs[index].id)
            onChosenVideo?()
        }
        sourceId = source
        playingAlbumId = Self.albumId(of: songs, source: source)
        index = min(max(0, index), songs.count - 1)
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
        playNextIds = []
        radioContinuation = nil
        radioSeed = nil
        queueGeneration += 1
        extendBlockedUntil = .distantPast
        library.remember(songs)
        start(index: index)
    }

    /// Plays one song and lets YouTube Music's radio fill the queue behind it.
    func play(song: Song) {
        play([song], chosen: true)
    }

    /// Plays the song and fills the queue with its YouTube Music radio straight away, with or
    /// without Autoplay. Before 2026-11-21 this only played the song: the radio came from
    /// Autoplay, so with Autoplay off the queue held the one song.
    func playRadio(for song: Song) {
        play([song])
        radioSeed = song.id
        extendQueueIfNeeded()
    }

    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        library.remember(songs)
        guard let currentIndex else {
            play(songs)
            return
        }
        let at = playNextIndex
        let after = queue[at - 1]
        queue.insert(contentsOf: songs, at: at)
        markQueuedByHand(songs.map(\.id), playNext: true)
        adoptVideos(songs)
        // The order to return to when shuffle is switched off has them in the same place.
        if var original = unshuffledQueue {
            let place = original.firstIndex(of: after).map { $0 + 1 } ?? min(original.count, currentIndex + 1)
            original.insert(contentsOf: songs, at: place)
            unshuffledQueue = original
        }
        persist()
        // Plan for the new pair now, not on the next tick, so what's shown is what will play.
        prepareMix()
    }

    func enqueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        library.remember(songs)
        guard currentIndex != nil else {
            play(songs)
            return
        }
        // Songs the listener adds go after their own queue but before what Autoplay or a radio
        // lined up, as in YouTube Music: Autoplay's songs stay at the end, where AutoMix orders them.
        var at = queue.count
        while at > firstFlexibleIndex, autoQueued[queue[at - 1].id] != nil { at -= 1 }
        queue.insert(contentsOf: songs, at: at)
        markQueuedByHand(songs.map(\.id), playNext: false)
        adoptVideos(songs)
        unshuffledQueue?.append(contentsOf: songs)
        persist()
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        start(index: index)
    }

    /// Device Connect: a paired phone has set the queue, the song and whether it plays. When the
    /// playing song is still the same one, playback carries on without a restart.
    func applyRemoteQueue(_ songs: [Song], index: Int, position: Double, playing: Bool, restart: Bool) {
        let previous = currentSong?.id
        unshuffledQueue = nil
        shuffle = false
        // Songs Autoplay added keep that mark while they are still queued, so a remote edit
        // (a phone adding one song) doesn't stop AutoMix from ordering the rest.
        let kept = Set(songs.map(\.id))
        autoQueued = autoQueued.filter { kept.contains($0.key) }
        playNextIds = playNextIds.filter { kept.contains($0) }
        library.remember(songs)
        guard songs.indices.contains(index) else {
            queue = []
            currentIndex = nil
            isPlaying = false
            engine.pause()
            persist()
            publishNowPlaying()
            return
        }
        queue = songs
        if !restart, previous == songs[index].id, !needsLoad {
            currentIndex = index
            persist()
            return
        }
        currentIndex = index
        isPlaying = playing
        errorMessage = nil
        loadCurrent(at: position)
        extendQueueIfNeeded()
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        let removed = queue.remove(at: index)
        if !queue.contains(where: { $0.id == removed.id }) { playNextIds.remove(removed.id) }
        if let place = unshuffledQueue?.firstIndex(of: removed) { unshuffledQueue?.remove(at: place) }
        prepareMix()
        if let currentIndex, index < currentIndex { self.currentIndex = currentIndex - 1 }
        persist()
    }

    func moveInQueue(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), destination >= 0, destination <= queue.count, source != destination else { return }
        let current = currentSong
        let song = queue.remove(at: source)
        queue.insert(song, at: destination > source ? destination - 1 : destination)
        // Moved by hand: the listener has placed it themselves.
        playNextIds.remove(song.id)
        prepareMix()
        if let current { currentIndex = queue.firstIndex(of: current) }
        persist()
    }

    /// Takes the songs of artists that were just hidden out of what's coming up.
    func removeBlockedFromUpcoming() {
        guard let currentIndex else { return }
        let before = queue.count
        var index = queue.count - 1
        while index > currentIndex {
            if ContentFilter.shared.isBlocked(queue[index]) { queue.remove(at: index) }
            index -= 1
        }
        if queue.count != before { persist() }
    }

    func clearUpcoming() {
        guard let currentIndex, currentIndex + 1 < queue.count else { return }
        queue.removeSubrange((currentIndex + 1)...)
        playNextIds = []
        radioContinuation = nil
        // Clearing ends a radio too, and a page already asked for is not added afterwards.
        radioSeed = nil
        queueGeneration += 1
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
        // Play Next songs (and one already fading in) stay where they are either way.
        let held = Array(queue[(currentIndex + 1) ..< firstFlexibleIndex])
        if shuffle {
            shuffle = false
            if var original = unshuffledQueue {
                for song in held { if let place = original.firstIndex(of: song) { original.remove(at: place) } }
                if let index = original.firstIndex(of: current) {
                    original.insert(contentsOf: held, at: index + 1)
                    queue = original
                    self.currentIndex = index
                }
            }
            unshuffledQueue = nil
        } else {
            shuffle = true
            unshuffledQueue = queue
            var rest = queue
            rest.removeSubrange(currentIndex ..< currentIndex + 1 + held.count)
            rest.shuffle()
            queue = [current] + held + rest
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

    /// Uses lyrics the listener picked from a search for the playing song.
    func useLyrics(_ candidate: LyricsCandidate) {
        guard let song = currentSong else { return }
        Task {
            await LyricsService.shared.removeUserCopy(for: song.id)
            await LyricsService.shared.store(candidate.lyrics, for: song.id)
            lyricsDidChange(for: song.id, to: candidate.lyrics)
        }
    }

    /// Saves lyrics the listener edited for the playing song.
    func saveEditedLyrics(_ edited: Lyrics) {
        guard let song = currentSong else { return }
        Task {
            await LyricsService.shared.saveUser(edited, for: song.id)
            lyricsDidChange(for: song.id, to: await LyricsService.shared.cached(song.id))
        }
    }

    /// Goes back to the provider's lyrics for the playing song, dropping the listener's edits.
    func discardEditedLyrics() {
        guard let song = currentSong else { return }
        Task {
            await LyricsService.shared.removeUserCopy(for: song.id)
            let found = await LyricsService.shared.fetch(for: song, duration: Double(song.duration ?? 0), forceRefresh: true)
            lyricsDidChange(for: song.id, to: found)
        }
    }

    /// New lyrics change where the singing is, so the transitions AutoMix planned for pairs with
    /// this song are planned again. Transitions the listener saved are never touched.
    private func lyricsDidChange(for videoId: String, to new: Lyrics?) {
        lyricsEpoch += 1
        mixLyrics[videoId] = .some(new)
        mixLyricsRequested.insert(videoId)
        for key in mixCandidates.keys where key.split(separator: "|").prefix(2).contains(where: { $0 == videoId }) {
            mixCandidates[key] = nil
        }
        planning.removeAll()
        if currentSong?.id == videoId {
            lyrics = new
            lyricsRequestedFor = videoId
        }
        MixLog.write("lyrics changed for \(videoId): transitions with it are planned again")
        prepareMix()
    }

    // MARK: - Loading

    private func start(index: Int) {
        currentIndex = index
        if queue.indices.contains(index) { becameCurrent(queue[index]) }
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
            if swapsForAudio(song) {
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
        // Only videos that arrived on their own are swapped, and for those the listener wants
        // the release even when the video is a longer cut (as the playlist page decides).
        let found = await YTMusic.audioCounterpart(for: song, strictLength: false)
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
                    beginListen(song)
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
        becameCurrent(song)
        gaplessKey = nil
        position = 0
        duration = engine.duration > 0 ? engine.duration : Double(song.duration ?? 0)
        lyrics = nil
        lyricsRequestedFor = nil
        media.protectedId = song.id
        recordedPlayFor = song.id
        library.recordPlay(song)
        beginListen(song)
        fetchLyrics(for: song)
        publishNowPlaying()
        persist()
        extendQueueIfNeeded()
    }

    /// A song has started to be heard: for AutoMix that is the hand-over, half-way through the
    /// overlap. Tells the scrobbling services what is now playing.
    private func beginListen(_ song: Song) {
        listenStartedAt = Date()
        listenPlayed = 0
        scrobbledFor = nil
        Scrobbler.shared.nowPlaying(song, duration: duration)
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
        // A listen counts after half the song, or four minutes, of actual playing.
        if status == .ready { listenPlayed += 0.25 }
        if scrobbledFor != playing.id, recordedPlayFor == playing.id, Scrobbler.counts(position: listenPlayed, duration: duration) {
            scrobbledFor = playing.id
            Scrobbler.shared.scrobble(playing, duration: duration, started: listenStartedAt)
        }
        prepareMix()
        separateStemsAhead()
        // Hand the next track to the engine ahead of time: with a mix plan it is cued for a
        // DJ-style transition, otherwise it follows without a gap.
        var key: String?
        var plan: MixPlan?
        if currentIndex + 1 < queue.count, repeatMode != .one {
            let upcoming = queue[currentIndex + 1]
            if !awaitingAudioVersion(upcoming) {
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

    /// The transition whose stems were last separated ahead of time.
    @ObservationIgnored private var stemsAheadFor: String?

    /// Whether both stretches of the upcoming transition are already separated.
    private func stemsSeparated(for plan: MixPlan) -> Bool {
        guard let currentIndex, currentIndex + 1 < queue.count,
              let first = media.records[queue[currentIndex].id], let second = media.records[queue[currentIndex + 1].id] else { return false }
        let stretches = MixEngine.stemStretches(plan)
        return StemSeparator.isCached(file: AppPaths.media.appendingPathComponent(first.fileName), from: stretches.outgoing.start, to: stretches.outgoing.end)
            && StemSeparator.isCached(file: AppPaths.media.appendingPathComponent(second.fileName), from: stretches.incoming.start, to: stretches.incoming.end)
    }

    /// Has the stems of the coming transition separated as soon as it is decided and both songs
    /// are on disk, so they are in place however soon it is cued (a preview jumps to 5 s before
    /// it, and separating takes 3 to 5 s; on 2026-11-21 stems arrived late and vocals bled).
    private func separateStemsAhead() {
        guard settings.mixStems, let mix = nextMixPlan, MixEngine.usesStems(mix), let currentIndex, currentIndex + 1 < queue.count,
              let first = media.records[queue[currentIndex].id], let second = media.records[queue[currentIndex + 1].id]
        else { return }
        let key = String(format: "%@|%@|%.3f|%.3f|%d|%.5f|%.5f", queue[currentIndex].id, queue[currentIndex + 1].id, mix.outStart, mix.inPoint, mix.beats, mix.periodA, mix.periodB)
        guard key != stemsAheadFor else { return }
        stemsAheadFor = key
        engine.separateStemsAhead(mix, current: AppPaths.media.appendingPathComponent(first.fileName), next: AppPaths.media.appendingPathComponent(second.fileName))
    }

    /// The album a list of songs makes up: started from an album page, or two or more songs
    /// that all come from the same album. Nil for playlists, mixes and single songs.
    static func albumId(of songs: [Song], source: String?) -> String? {
        if let source, source.hasPrefix("MPRE") { return source }
        guard songs.count > 1, let first = songs.first?.album?.id else { return nil }
        return songs.allSatisfy { $0.album?.id == first } ? first : nil
    }

    /// Appends radio tracks when the queue is about to run out (Autoplay), or as soon as the
    /// listener starts a radio.
    private func extendQueueIfNeeded() {
        let generation = queueGeneration
        let radio = radioSeed != nil
        guard settings.autoplay || radio, extendingGeneration != generation, repeatMode == .off || radio, playingAlbumId == nil,
              // With AutoMix choosing the order, keep enough lined up to choose between.
              let currentIndex, queue.count - currentIndex <= (sequencesAutoQueue ? MixSequencer.pool + 1 : 2), let seed = queue.last,
              NetworkStatus.shared.isOnline, Date() >= extendBlockedUntil
        else { return }
        extendingGeneration = generation
        let continuation = radioContinuation
        // A radio's first page comes from the song it was started for, even if that song has
        // since been swapped for its audio release.
        let seedId = continuation == nil && queue.count == 1 ? (radioSeed ?? seed.id) : seed.id
        Task {
            defer { if extendingGeneration == generation { extendingGeneration = nil } }
            let page: QueuePage?
            if let continuation {
                page = try? await YTMusic.queue(continuation: continuation)
            } else {
                page = try? await YTMusic.radio(for: seedId)
            }
            // The queue was replaced while this was asked for: this page belongs to the old one.
            guard generation == queueGeneration else { return }
            guard let page else {
                extendBlockedUntil = Date().addingTimeInterval(30)
                return
            }
            // A video in the queue may have been swapped for its audio release, and a radio page
            // lists songs under either id: neither may come round again.
            var existing = Set(queue.map(\.id))
            for (video, audio) in counterparts { if let audio, existing.contains(audio.id) { existing.insert(video) } }
            var unseen: [Song] = []
            var listed = existing
            for song in page.songs {
                let other = page.counterparts[song.id]?.id
                guard !listed.contains(song.id), !(other.map(listed.contains) ?? false) else { continue }
                listed.insert(song.id)
                if let other { listed.insert(other) }
                unseen.append(song)
            }
            // After a music video, only music videos: each song's video counterpart (as
            // YouTube Music's own audio/video switch pairs them), or the video itself.
            let videosOnly = isVideoSession
            if videosOnly {
                var seen = existing
                unseen = page.songs.compactMap { song -> Song? in
                    let video = song.isMusicVideo ? song : page.counterparts[song.id].flatMap { $0.isMusicVideo ? $0 : nil }
                    guard let video, seen.insert(video.id).inserted else { return nil }
                    return video
                }
            }
            // Hidden artists and the AI-artist list are filtered out here, before anything is
            // queued, so their songs are never downloaded or analysed.
            let fresh = ContentFilter.shared.filter(unseen)
            if videosOnly { chosenVideos.formUnion(fresh.map(\.id)) }
            appendAutoQueued(fresh)
            radioContinuation = page.continuation
            library.remember(fresh)
            if fresh.isEmpty, !unseen.isEmpty || (videosOnly && !page.songs.isEmpty && page.continuation != nil) {
                // Everything on this page was filtered (or, after a video, had no video):
                // look at the next one soon.
                extendBlockedUntil = Date().addingTimeInterval(2)
            } else if fresh.isEmpty {
                // Stop asking when the radio has nothing new, to avoid a request loop.
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
        DiscordPresence.shared.update(song: song, playing: isPlaying, position: position, duration: duration)
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
        playingAlbumId = Self.albumId(of: saved.queue, source: nil)
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
