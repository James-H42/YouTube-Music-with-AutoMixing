import AVFoundation

/// Two decks and a mixer. With AutoMix off it behaves exactly like a single `AudioEngine`
/// (including gapless hand-over). With a `MixPlan`, it cues the next track on the idle deck,
/// starts it on the planned beat and automates faders, EQ, echo, tempo and pitch across the
/// overlap, following the plan's curves.
final class MixEngine: @unchecked Sendable {
    /// Progress of a transition, for the interface.
    struct Activity: Equatable {
        var plan: MixPlan
        var progress: Double
    }

    var onStatus: ((AudioEngine.Status) -> Void)?
    var onEnded: (() -> Void)?
    var onAdvanced: ((String) -> Void)?
    /// Delivered on the main queue; nil when no transition is running.
    var onActivity: ((Activity?) -> Void)?

    private let decks = [AudioEngine(), AudioEngine()]
    private let queue = DispatchQueue(label: "metrolist.mix-engine", qos: .userInitiated)
    private let lock = NSLock()
    private var activeIndex = 0

    // Confined to `queue`.
    private var pending: (media: OpenedMedia, plan: MixPlan)?
    private var transition: Transition?
    private var settle: Settle?
    private var timer: DispatchSourceTimer?
    private var isPlaying = false
    private var statuses: [AudioEngine.Status] = [.idle, .idle]
    private var waitingLogged = false

    private struct Transition {
        var plan: MixPlan
        var media: OpenedMedia
        var from: Int
        var to: Int
        /// Host time (seconds) when the incoming deck starts sounding.
        var startTime: Double
        /// Length of the overlap in real time.
        var duration: Double
        /// The outgoing deck is on the time-stretcher, so it can follow the plan's tempo and
        /// pitch glides. Otherwise only the incoming deck is adjusted.
        var glide: Bool
        var pausedAt: Double?
        var handedOver = false
        /// Smoothed beat-phase error between the decks, in beats.
        var drift = 0.0
    }

    /// After a transition, the new track eases back to its own tempo and pitch.
    private struct Settle {
        var deck: Int
        var rate: Float
        var pitch: Float
        var startedAt: Double
        var seconds = 8.0
    }

    init() {
        for (index, deck) in decks.enumerated() {
            deck.onStatus = { [weak self] status in
                self?.queue.async { self?.deckStatus(index, status) }
            }
            deck.onEnded = { [weak self] in
                self?.queue.async { self?.deckEnded(index) }
            }
            deck.onAdvanced = { [weak self] videoId in
                self?.queue.async {
                    guard let self, index == self.active else { return }
                    DispatchQueue.main.async { self.onAdvanced?(videoId) }
                }
            }
        }
    }

    private var active: Int { lock.withLock { activeIndex } }
    private var activeDeck: AudioEngine { decks[active] }

    // MARK: - State

    var currentTime: Double { activeDeck.currentTime }
    var duration: Double { activeDeck.duration }

    var volume: Float {
        get { decks[0].volume }
        set { decks.forEach { $0.volume = newValue } }
    }

    /// Plays both decks through one output (nil: the system's default).
    func setOutputDevice(_ id: UInt32?) {
        decks.forEach { $0.setOutputDevice(id) }
    }

    /// Positions of both decks, for tests that measure beat alignment.
    var deckTimes: (Double, Double) { (decks[0].preciseTime, decks[1].preciseTime) }
    var deckLevels: (Float, Float) { (decks[0].meter, decks[1].meter) }
    var deckRates: (Float, Float) { (decks[0].rate, decks[1].rate) }
    var activeDeckIndex: Int { active }

    func enableMeters() {
        decks.forEach { $0.enableMeter() }
    }

    // MARK: - Transport

    /// `mixReady` routes the track through the time-stretcher so that it can change tempo
    /// during a transition out of it. Leave it off for plain playback.
    func load(_ media: OpenedMedia, startAt: Double, autoplay: Bool, normalize: Bool, mixReady: Bool = false) {
        queue.async { [self] in
            cancelMix(stopIncoming: true)
            settle = nil
            isPlaying = autoplay
            decks[1 - active].stop()
            activeDeck.prepare(stretch: mixReady)
            activeDeck.load(media, startAt: startAt, autoplay: autoplay, normalize: normalize)
        }
    }

    func play() {
        queue.async { [self] in
            isPlaying = true
            if var running = transition, let pausedAt = running.pausedAt {
                running.startTime += Self.now() - pausedAt
                running.pausedAt = nil
                transition = running
                decks[running.from].play()
                decks[running.to].play()
            } else {
                activeDeck.play()
            }
        }
    }

    func pause() {
        queue.async { [self] in
            isPlaying = false
            if var running = transition {
                if running.pausedAt == nil { running.pausedAt = Self.now() }
                transition = running
                decks[running.from].pause()
                decks[running.to].pause()
            } else {
                activeDeck.pause()
            }
        }
    }

    func seek(to seconds: Double) {
        queue.async { [self] in
            // Seeking abandons a transition in favour of whichever track is "current".
            cancelMix(stopIncoming: true)
            activeDeck.seek(to: seconds)
        }
    }

    func stop() {
        queue.async { [self] in
            cancelMix(stopIncoming: true)
            decks.forEach { $0.stop() }
        }
    }

    /// Queues the track that follows. With a plan it is mixed in; without one it follows
    /// gaplessly. Passing nil clears whatever was queued.
    func enqueueNext(_ upcoming: OpenedMedia?, plan: MixPlan? = nil, normalize: Bool = true) {
        queue.async { [self] in
            guard transition == nil else { return }
            cancelMix(stopIncoming: true)
            guard let upcoming else {
                activeDeck.enqueueNext(nil)
                return
            }
            guard let plan else {
                activeDeck.enqueueNext(upcoming)
                return
            }
            activeDeck.enqueueNext(nil)
            pending = (upcoming, plan)
            waitingLogged = false
            MixLog.write(String(format: "cued %@: out at %.2f s, in at %.2f s (now at %.2f s)", plan.summary, plan.outStart, plan.inPoint, activeDeck.currentTime))
            if let loop = plan.loop { activeDeck.setLoop(start: loop.start, length: loop.length) }
            let incoming = decks[1 - active]
            incoming.stop()
            incoming.prepare(stretch: true)
            incoming.load(upcoming, startAt: plan.inPoint, autoplay: false, normalize: normalize)
            // Faders, EQ and tempo are set when the transition starts: loading resets them.
            startTimer()
        }
    }

    // MARK: - Deck events (mix queue)

    private func deckStatus(_ index: Int, _ status: AudioEngine.Status) {
        statuses[index] = status
        guard index == active else { return }
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func deckEnded(_ index: Int) {
        if let running = transition {
            // The outgoing track running out mid-blend is expected; the incoming one ending
            // would mean something is badly wrong, so let the player move on.
            if index == running.to, running.handedOver {
                finishTransition()
                DispatchQueue.main.async { self.onEnded?() }
            }
            return
        }
        guard index == active else { return }
        // The mix point was never reached (for example the track was cut short).
        cancelMix(stopIncoming: true)
        DispatchQueue.main.async { self.onEnded?() }
    }

    // MARK: - Automation (mix queue)

    private static func now() -> Double {
        Double(AVAudioTime.seconds(forHostTime: mach_absolute_time()))
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTimerIfIdle() {
        guard pending == nil, transition == nil, settle == nil else { return }
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if transition == nil, let pending { watchForMixPoint(pending) }
        if let running = transition, running.pausedAt == nil { advance(running) }
        if let easing = settle, transition == nil {
            let elapsed = Self.now() - easing.startedAt
            let amount = Float(min(1, max(0, elapsed / easing.seconds)))
            // Ease in and out, so neither the start nor the end of the glide is noticeable.
            let eased = amount * amount * (3 - 2 * amount)
            decks[easing.deck].rate = easing.rate + (1 - easing.rate) * eased
            decks[easing.deck].pitch = easing.pitch * (1 - eased)
            if amount >= 1 {
                settle = nil
                stopTimerIfIdle()
            }
        }
    }

    private func apply(_ levels: MixPlan.Levels, to deck: AudioEngine, echoTime: Double) {
        deck.fadeGain = levels.gain
        deck.setEQ(bass: levels.bass, mid: levels.mid, high: levels.high, highPass: levels.highPass)
        deck.setEcho(levels.echo, time: echoTime)
    }

    private func watchForMixPoint(_ pending: (media: OpenedMedia, plan: MixPlan)) {
        guard isPlaying, statuses[active] == .ready else { return }
        var plan = pending.plan
        let incoming = 1 - active
        // Before the overlap the playing track eases to the speed and pitch it mixes at. This
        // follows its position, so pausing or seeking back simply moves along the same curve.
        if activeDeck.canStretch, let state = plan.approachState(at: activeDeck.currentTime) {
            settle = nil
            activeDeck.rate = Float(state.rate)
            activeDeck.pitch = Float(state.pitch)
        }
        let outgoingRate = max(0.5, Double(activeDeck.rate))
        let remaining = (plan.outStart - activeDeck.currentTime) / outgoingRate
        if remaining < -0.25 {
            // Past the mix point: the next track was not ready in time, or playback was moved.
            // If the next track is ready and enough of this one is left, mix a little later
            // (a whole number of bars later, to stay on the phrase) rather than not at all.
            let length = plan.duration(glide: false)
            let left = activeDeck.duration - activeDeck.currentTime
            if statuses[incoming] == .ready, plan.loop == nil, left > length * 0.6 + 1, decks[incoming].currentTime <= plan.inPoint + 0.05 {
                var later = plan
                let bar = plan.sync ? 4 * plan.periodA : 0.5
                later.outStart += ((-remaining * outgoingRate + 0.6) / bar).rounded(.up) * bar
                MixLog.write(String(format: "late for the mix point by %.1f s; moving it to %.2f s", -remaining, later.outStart))
                self.pending = (pending.media, later)
                return
            }
            if remaining < -1.5 || left <= length * 0.6 + 1 {
                MixLog.write(String(format: "mix abandoned: %.1f s past the mix point, next track %@, %.1f s left", -remaining, "\(statuses[incoming])", left))
                self.pending = nil
                decks[incoming].stop()
                activeDeck.clearLoop()
                activeDeck.enqueueNext(pending.media)
                stopTimerIfIdle()
            }
            return
        }
        // The incoming deck must be cued and buffered before it can be dropped in on time.
        let preroll = activeDeck.outputLatency + decks[incoming].stretchLatency
        guard remaining <= 0.15 + preroll else { return }
        guard statuses[incoming] == .ready else {
            if !waitingLogged {
                waitingLogged = true
                MixLog.write("mix point reached but the next track is not ready (\(statuses[incoming])); waiting")
            }
            return
        }

        // `currentTime` is what is audible; nodes are scheduled in render time, which runs
        // ahead by the output latency. The stretcher adds its own delay to the new deck.
        let glide = activeDeck.canStretch
        if !glide, plan.approach != nil {
            // This track was loaded before AutoMix was on and cannot change speed, so the
            // planned move is out of reach: fall back to a plain cross-fade of the same length.
            plan.seconds = plan.duration(glide: true)
            plan.sync = false
            plan.approach = nil
            plan.outgoingRate = nil
        }
        settle = nil
        let echoTime = plan.periodA * 0.75
        apply(plan.levels(outgoing: false, at: 0), to: decks[incoming], echoTime: echoTime)
        decks[incoming].rate = Float(plan.rates(at: 0, glide: glide).incoming)
        // The outgoing track is the one that bends to meet the new key. If it can't (it was
        // loaded before AutoMix was on), the incoming one is shifted the other way instead.
        decks[incoming].pitch = Float(plan.pitchShift - (glide ? 0 : (plan.outgoingPitch ?? 0)))
        MixLog.write(String(format: "starting %@ at %.2f s (planned %.2f), next from %.2f s, %.1f s long, glide %@", plan.summary, activeDeck.currentTime, plan.outStart, plan.inPoint, plan.duration(glide: glide), glide ? "yes" : "no"))
        let lead = max(0.02, remaining - preroll)
        let startTime = Self.now() + lead
        decks[incoming].play(atHostTime: AVAudioTime.hostTime(forSeconds: startTime))
        transition = Transition(
            plan: plan, media: pending.media, from: active, to: incoming,
            startTime: startTime + preroll,
            duration: plan.duration(glide: glide), glide: glide
        )
        self.pending = nil
    }

    private func advance(_ running: Transition) {
        let plan = running.plan
        let progress = (Self.now() - running.startTime) / running.duration
        guard progress >= 0 else { return }
        let echoTime = plan.periodA * 0.75
        apply(plan.levels(outgoing: true, at: progress), to: decks[running.from], echoTime: echoTime)
        apply(plan.levels(outgoing: false, at: progress), to: decks[running.to], echoTime: echoTime)

        let rates = plan.rates(at: min(1, progress), glide: running.glide)
        var incomingRate = rates.incoming
        if plan.sync, plan.loop == nil, progress > 0.03, statuses[running.from] == .ready, statuses[running.to] == .ready {
            // Keep the beats locked: compare how far each deck has travelled, in beats, and
            // nudge the incoming one. This absorbs timing error at the start and tempo drift.
            let beatsA = (decks[running.from].preciseTime - plan.outStart) / plan.periodA
            let beatsB = (decks[running.to].preciseTime - plan.inPoint) / plan.periodB
            let error = beatsB - beatsA
            if abs(error) < 0.45 {
                let drift = running.drift + (error - running.drift) * 0.08
                transition?.drift = drift
                incomingRate *= 1 + max(-0.025, min(0.025, -drift * 0.6))
            }
        }
        if running.glide {
            decks[running.from].rate = Float(rates.outgoing)
            if let bend = plan.outgoingPitch, bend != 0 { decks[running.from].pitch = Float(bend * plan.pitchAmount(at: progress)) }
        }
        decks[running.to].rate = Float(incomingRate)

        let activity = Activity(plan: plan, progress: min(1, progress))
        DispatchQueue.main.async { self.onActivity?(activity) }

        if progress >= 0.5, !running.handedOver {
            // From the midpoint the new track is the one the player shows and controls.
            transition?.handedOver = true
            lock.withLock { activeIndex = running.to }
            let videoId = running.media.videoId
            let status = statuses[running.to]
            DispatchQueue.main.async {
                self.onAdvanced?(videoId)
                self.onStatus?(status)
            }
        }
        if progress >= 1 { finishTransition() }
    }

    private func finishTransition() {
        guard let running = transition else { return }
        transition = nil
        decks[running.from].stop()
        let deck = decks[running.to]
        deck.fadeGain = 1
        deck.setEQ()
        deck.setEcho(0)
        if !running.handedOver {
            lock.withLock { activeIndex = running.to }
            let videoId = running.media.videoId
            DispatchQueue.main.async { self.onAdvanced?(videoId) }
        }
        // Ease the new track back to its own tempo and key.
        if abs(deck.rate - 1) > 0.001 || abs(deck.pitch) > 0.01 {
            // The further it has to travel, the longer it takes over it.
            let seconds = max(8, 150 * Double(abs(deck.rate - 1)), 6 * Double(abs(deck.pitch)))
            settle = Settle(deck: running.to, rate: deck.rate, pitch: deck.pitch, startedAt: Self.now(), seconds: min(24, seconds))
        } else {
            deck.rate = 1
            deck.pitch = 0
        }
        DispatchQueue.main.async { self.onActivity?(nil) }
        stopTimerIfIdle()
    }

    /// Abandons a cued or running mix, leaving the current track playing on its own.
    private func cancelMix(stopIncoming: Bool) {
        if let running = transition {
            transition = nil
            let keep = running.handedOver ? running.to : running.from
            let drop = running.handedOver ? running.from : running.to
            decks[drop].stop()
            decks[keep].fadeGain = 1
            decks[keep].setEQ()
            decks[keep].setEcho(0)
            decks[keep].rate = 1
            decks[keep].pitch = 0
            decks[keep].clearLoop()
            DispatchQueue.main.async { self.onActivity?(nil) }
        } else if pending != nil {
            if stopIncoming { decks[1 - active].stop() }
            activeDeck.clearLoop()
            // Part-way through an approach: ease back rather than jump. (A re-cued plan takes
            // over again on the next tick.)
            if abs(activeDeck.rate - 1) > 0.001 || abs(activeDeck.pitch) > 0.01 {
                settle = Settle(deck: active, rate: activeDeck.rate, pitch: activeDeck.pitch, startedAt: Self.now(), seconds: 1.5)
                startTimer()
            }
        }
        pending = nil
        stopTimerIfIdle()
    }
}

/// A short running record of what AutoMix did and why, in `mix.log` beside the app's data,
/// so a transition that did not happen can be explained afterwards.
enum MixLog {
    private static let queue = DispatchQueue(label: "metrolist.mix-log", qos: .utility)
    private static let url = AppPaths.root.appendingPathComponent("mix.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard))  \(message)\n"
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > 200_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
