import Accelerate
import AVFoundation

private enum PCMRead {
    case buffer(AVAudioPCMBuffer, time: Double)
    case needMoreData
    case end
}

private protocol PCMReader: AnyObject {
    var format: AVAudioFormat { get }
    var duration: Double? { get }
    func seek(to seconds: Double)
    func read() -> PCMRead
}

/// Streams Opus out of a (possibly still downloading) WebM file.
private final class OpusReader: PCMReader {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let demuxer: WebMDemuxer
    private var decoder: OpusDecoder?
    private var pendingSeek: Double?
    /// Packets that start before this time are skipped (or decoded and discarded as pre-roll).
    private var keepFrom = 0.0

    init(source: ByteSource) {
        demuxer = WebMDemuxer(source: source)
    }

    var duration: Double? { demuxer.durationSeconds }

    func seek(to seconds: Double) {
        pendingSeek = seconds
        keepFrom = seconds
        decoder?.reset()
    }

    func read() -> PCMRead {
        while true {
            if let target = pendingSeek, demuxer.isReady {
                demuxer.seek(to: target)
                pendingSeek = nil
            }
            switch demuxer.next() {
            case .needMoreData:
                return .needMoreData
            case .endOfStream:
                return .end
            case .packet(let packet):
                if pendingSeek != nil { continue }
                if decoder == nil {
                    guard let created = OpusDecoder(channels: demuxer.track?.channels ?? 2) else { return .end }
                    decoder = created
                }
                let time = Double(packet.timeNs) / 1_000_000_000
                // Opus needs ~80 ms of decoded pre-roll after a seek to converge.
                if time + 0.02 < keepFrom - 0.1 { continue }
                guard var buffer = decoder?.decode(packet.data) else { continue }
                if time + 0.02 <= keepFrom { continue }
                // Sample-accurate edges, so consecutive tracks join without a gap or click.
                // Start: Opus streams open with priming samples (CodecDelay). The system
                // decoder already swallows some of them, visible as a short first buffer.
                if time == 0, let delay = demuxer.track?.codecDelayNs, delay > 0 {
                    let priming = Int(Double(delay) / 1_000_000_000 * 48_000)
                    let alreadyDropped = max(0, 960 - Int(buffer.frameLength))
                    let skip = AVAudioFrameCount(max(0, priming - alreadyDropped))
                    if skip > 0 {
                        guard buffer.frameLength > skip,
                              let trimmed = Self.slice(buffer, from: skip, count: buffer.frameLength - skip) else { continue }
                        buffer = trimmed
                    }
                }
                // End: the final packet declares how much of it is encoder padding.
                if packet.discardPaddingNs > 0 {
                    let padding = AVAudioFrameCount(Double(packet.discardPaddingNs) / 1_000_000_000 * 48_000)
                    guard buffer.frameLength > padding,
                          let trimmed = Self.slice(buffer, from: 0, count: buffer.frameLength - padding) else { continue }
                    buffer = trimmed
                }
                // Start exactly on the requested sample rather than on a packet edge, so a
                // cued mix point or a loop lands on the beat.
                if time < keepFrom - 0.0005 {
                    let skip = AVAudioFrameCount((keepFrom - time) * 48_000)
                    guard skip < buffer.frameLength else { continue }
                    if skip > 0, let trimmed = Self.slice(buffer, from: skip, count: buffer.frameLength - skip) {
                        return .buffer(trimmed, time: keepFrom)
                    }
                }
                return .buffer(buffer, time: time)
            }
        }
    }
}

extension OpusReader {
    static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count > 0, start + count <= buffer.frameLength,
              let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let source = buffer.floatChannelData, let target = result.floatChannelData
        else { return nil }
        for channel in 0 ..< Int(buffer.format.channelCount) {
            memcpy(target[channel], source[channel] + Int(start), Int(count) * MemoryLayout<Float>.size)
        }
        result.frameLength = count
        return result
    }
}

/// Reads a complete local file (the AAC fallback) through Core Audio.
private final class FileReader: PCMReader {
    private let file: AVAudioFile
    let format: AVAudioFormat

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        self.file = file
        format = file.processingFormat
    }

    var duration: Double? { Double(file.length) / format.sampleRate }

    func seek(to seconds: Double) {
        file.framePosition = min(file.length, AVAudioFramePosition(max(0, seconds) * format.sampleRate))
    }

    func read() -> PCMRead {
        let time = Double(file.framePosition) / format.sampleRate
        guard file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192),
              (try? file.read(into: buffer)) != nil, buffer.frameLength > 0
        else { return .end }
        return .buffer(buffer, time: time)
    }
}

/// Plays one track at a time through AVAudioEngine, decoding progressively so playback can
/// start while the file is still downloading.
final class AudioEngine: @unchecked Sendable {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case buffering
        case ended
        case failed(String)
    }

    /// Both callbacks are delivered on the main queue.
    var onStatus: ((Status) -> Void)?
    var onEnded: (() -> Void)?
    /// Playback flowed straight into the queued next track (gapless); carries its video id.
    var onAdvanced: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 4)
    private let timePitch = AVAudioUnitTimePitch()
    /// The deck's fader. A player node's own volume only works when it feeds a mixer directly.
    private let fader = AVAudioMixerNode()
    private let delay = AVAudioUnitDelay()
    private let queue = DispatchQueue(label: "metrolist.audio-engine", qos: .userInitiated)

    // Confined to `queue`.
    private var generation = 0
    private var media: OpenedMedia?
    private var observer: UUID?
    private var reader: PCMReader?
    private var connectedFormat: AVAudioFormat?
    private var wantsPlaying = false
    private var queuedFrames: Int64 = 0
    private var awaitingBase = true
    private var startPosition = 0.0
    private var reachedEnd = false
    private var lastStatus: Status = .idle
    private var normalize = true
    private var wantsStretch = false
    private var connectedStretch = false
    private var startHostTime: UInt64?
    /// Section being repeated: reading jumps back to `start` each time it reaches `end`.
    private var loop: (start: Double, end: Double)?
    private var meterInstalled = false
    /// Loudness gain baked into the samples of the track currently being scheduled, so two
    /// tracks queued back to back each keep their own level.
    private var readerGain: Float = 1
    /// Track queued to follow the current one without stopping the output.
    private var nextMedia: OpenedMedia?
    private var nextObserver: UUID?
    /// The track still audible while buffers of the next one are already scheduled.
    private var previous: (media: OpenedMedia, reader: PCMReader)?

    // Shared with readers on other threads.
    private let lock = NSLock()
    private var nodePlaying = false
    private var baseTime = 0.0
    private var scheduledFrames: Int64 = 0
    private var sampleRate = 48_000.0
    private var lastTime = 0.0
    private var knownDuration = 0.0
    private var latency = 0.0
    /// Delay of the time-stretcher while it is in the signal path, else 0.
    private var stretchDelay = 0.0
    private var stretchActive = false
    private var meterValue: Float = 0

    init() {
        engine.attach(node)
        engine.attach(equalizer)
        engine.attach(timePitch)
        engine.attach(fader)
        engine.attach(delay)
        // A DJ mixer's three-band EQ, plus a high-pass that thins a track out as it leaves.
        equalizer.bands[0].filterType = .lowShelf
        equalizer.bands[0].frequency = 180
        equalizer.bands[1].filterType = .parametric
        equalizer.bands[1].frequency = 1_000
        equalizer.bands[1].bandwidth = 2.2
        equalizer.bands[2].filterType = .highShelf
        equalizer.bands[2].frequency = 5_000
        for band in 0 ..< 3 {
            equalizer.bands[band].gain = 0
            equalizer.bands[band].bypass = false
        }
        equalizer.bands[3].filterType = .highPass
        equalizer.bands[3].frequency = 30
        equalizer.bands[3].bypass = true
        equalizer.bypass = true
        timePitch.overlap = 16
        delay.wetDryMix = 0
        delay.feedback = 55
        delay.lowPassCutoff = 5_500
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.handleConfigurationChange() }
        }
    }

    // MARK: - Public state

    var duration: Double { lock.withLock { knownDuration } }

    /// Position of the audio currently leaving the speakers, in seconds.
    var currentTime: Double {
        lock.lock()
        defer { lock.unlock() }
        guard nodePlaying,
              let renderTime = node.lastRenderTime, renderTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: renderTime)
        else { return lastTime }
        let played = Double(max(0, playerTime.sampleTime)) / playerTime.sampleRate
        let upper = baseTime + Double(scheduledFrames) / sampleRate
        lastTime = max(max(0, baseTime), min(upper, baseTime + played - latency - stretchDelay * Double(timePitch.rate)))
        return lastTime
    }

    /// Like `currentTime`, but extrapolated from the last render cycle to this instant. Used to
    /// compare two decks, whose render cycles are not aligned with each other.
    var preciseTime: Double {
        lock.lock()
        defer { lock.unlock() }
        guard nodePlaying,
              let renderTime = node.lastRenderTime, renderTime.isSampleTimeValid, renderTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: renderTime)
        else { return lastTime }
        let rate = Double(timePitch.rate)
        let sinceRender = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: renderTime.hostTime)
        let played = Double(max(0, playerTime.sampleTime)) / playerTime.sampleRate + max(0, min(0.1, sinceRender)) * (stretchActive ? rate : 1)
        return baseTime + played - latency - stretchDelay * rate
    }

    /// True when this deck is routed through the time-stretcher and can change tempo and pitch.
    var canStretch: Bool { lock.withLock { stretchActive } }

    /// Output level of this deck after its fader (RMS), once `enableMeter()` has been called.
    var meter: Float { lock.withLock { meterValue } }

    func enableMeter() {
        queue.async { [self] in
            guard !meterInstalled else { return }
            meterInstalled = true
            fader.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
                guard let self, let channels = buffer.floatChannelData else { return }
                var rms: Float = 0
                vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(buffer.frameLength))
                self.lock.withLock { self.meterValue = rms }
            }
        }
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    // MARK: - Deck controls (used by AutoMix)

    /// Fader level of this deck, independent of the user's volume.
    var fadeGain: Float {
        get { fader.outputVolume }
        set { fader.outputVolume = max(0, min(1, newValue)) }
    }

    /// Playback speed with pitch preserved. Only effective after `prepare(stretch: true)`.
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = max(0.5, min(2, newValue)) }
    }

    /// Pitch shift in semitones, independent of speed. Only effective on the stretch path.
    var pitch: Float {
        get { timePitch.pitch / 100 }
        set { timePitch.pitch = max(-900, min(900, newValue * 100)) }
    }

    var outputLatency: Double { lock.withLock { latency } }

    /// Delay added by the time-stretcher, so a timed start can compensate for it.
    var stretchLatency: Double { lock.withLock { stretchDelay } }

    /// Three-band EQ gains in dB and an optional high-pass cutoff; flat settings bypass the EQ.
    func setEQ(bass: Float = 0, mid: Float = 0, high: Float = 0, highPass: Float? = nil) {
        equalizer.bands[0].gain = bass
        equalizer.bands[1].gain = mid
        equalizer.bands[2].gain = high
        if let highPass {
            equalizer.bands[3].frequency = highPass
            equalizer.bands[3].bypass = false
        } else {
            equalizer.bands[3].bypass = true
        }
        equalizer.bypass = bass == 0 && mid == 0 && high == 0 && highPass == nil
    }

    /// Echo send (0…1) and the echo's spacing in seconds. Only effective on the stretch path.
    func setEcho(_ amount: Float, time: Double? = nil) {
        if let time { delay.delayTime = max(0.05, min(1.5, time)) }
        delay.wetDryMix = max(0, min(1, amount)) * 55
    }

    /// Repeats a section of the loaded track until cleared with nil.
    func setLoop(start: Double, length: Double) {
        queue.async { [self] in loop = length > 0.05 ? (start, start + length) : nil }
    }

    func clearLoop() {
        queue.async { [self] in loop = nil }
    }

    /// Chooses whether the next loaded track is routed through the time-stretcher.
    func prepare(stretch: Bool) {
        queue.async { [self] in wantsStretch = stretch }
    }

    /// Starts a loaded, paused deck at an exact host time so it lands on the beat.
    func play(atHostTime hostTime: UInt64) {
        queue.async { [self] in
            startHostTime = hostTime
            wantsPlaying = true
            pump()
        }
    }

    // MARK: - Transport

    func load(_ media: OpenedMedia, startAt: Double, autoplay: Bool, normalize: Bool) {
        queue.async { [self] in
            teardown()
            self.media = media
            self.normalize = normalize
            wantsPlaying = autoplay
            startPosition = max(0, startAt)
            lock.withLock {
                baseTime = startPosition
                lastTime = startPosition
                knownDuration = 0
            }
            setStatus(.loading)
            if let download = media.download {
                observer = download.addObserver { [weak self] in
                    self?.queue.async { self?.pump() }
                }
            }
            pump()
        }
    }

    /// Queues the track that should follow the current one seamlessly, or clears it with nil.
    func enqueueNext(_ upcoming: OpenedMedia?) {
        queue.async { [self] in
            guard media != nil, previous == nil else { return }
            if let nextObserver { nextMedia?.download?.removeObserver(nextObserver) }
            nextObserver = nil
            nextMedia = upcoming
            if let download = upcoming?.download {
                nextObserver = download.addObserver { [weak self] in
                    self?.queue.async { self?.pump() }
                }
            }
        }
    }

    func play() {
        queue.async { [self] in
            wantsPlaying = true
            if reachedEnd, queuedFrames <= 0 { performSeek(0) } else { pump() }
        }
    }

    func pause() {
        queue.async { [self] in
            wantsPlaying = false
            updatePlayback()
        }
    }

    func seek(to seconds: Double) {
        queue.async { [self] in performSeek(seconds) }
    }

    func stop() {
        queue.async { [self] in
            teardown()
            setStatus(.idle)
        }
    }

    // MARK: - Internals (audio queue)

    private func teardown() {
        generation += 1
        if let observer { media?.download?.removeObserver(observer) }
        observer = nil
        if let nextObserver { nextMedia?.download?.removeObserver(nextObserver) }
        nextObserver = nil
        nextMedia = nil
        previous = nil
        startHostTime = nil
        captureTime()
        node.stop()
        fader.outputVolume = 1
        timePitch.rate = 1
        timePitch.pitch = 0
        delay.wetDryMix = 0
        loop = nil
        setEQ()
        lock.withLock {
            nodePlaying = false
            scheduledFrames = 0
        }
        queuedFrames = 0
        reader = nil
        media = nil
        reachedEnd = false
        awaitingBase = true
    }

    private func performSeek(_ seconds: Double) {
        guard media != nil else { return }
        if let audible = previous {
            // The next track is scheduled but not yet audible: undo the hand-over.
            if let observer { media?.download?.removeObserver(observer) }
            observer = nil
            nextMedia = media
            media = audible.media
            reader = audible.reader
            readerGain = gain(for: audible.media)
            previous = nil
        }
        generation += 1
        node.stop()
        let target = max(0, min(seconds, duration > 0 ? max(0, duration - 0.25) : seconds))
        lock.withLock {
            nodePlaying = false
            scheduledFrames = 0
            baseTime = target
            lastTime = target
        }
        queuedFrames = 0
        reachedEnd = false
        awaitingBase = true
        startPosition = target
        reader?.seek(to: target)
        if lastStatus == .ended { lastStatus = .buffering }
        pump()
    }

    private func makeReader() -> PCMReader? {
        guard let media else { return nil }
        return makeReader(for: media, reportFailure: true)
    }

    private func makeReader(for media: OpenedMedia, reportFailure: Bool) -> PCMReader? {
        guard let head = media.source.read(offset: 0, length: 4) else {
            if reportFailure, let download = media.download, case .failed(let error) = download.state {
                fail(error.localizedDescription)
            }
            return nil
        }
        if [UInt8](head) == [0x1A, 0x45, 0xDF, 0xA3] {
            return OpusReader(source: media.source)
        }
        // Anything else is the MP4/AAC fallback, which Core Audio needs as a whole file.
        guard let total = media.source.totalBytes, media.source.availableBytes >= total, let url = media.fileURL else { return nil }
        guard let fileReader = FileReader(url: url) else {
            if reportFailure { fail("This track's audio format isn't supported.") }
            return nil
        }
        return fileReader
    }

    private func pump() {
        guard media != nil, lastStatus != .ended else { return }
        if case .failed = lastStatus { return }

        if reader == nil {
            guard let created = makeReader() else { return }
            reader = created
            configure(format: created.format)
            if startPosition > 0 { created.seek(to: startPosition) }
            readerGain = gain(for: media)
        }
        guard reader != nil else { return }

        let target = Int64(sampleRate * 3)
        var starved = false
        var startsNextTrack = false
        while queuedFrames < target, !reachedEnd, !starved, let reader {
            switch reader.read() {
            case .buffer(var buffer, let time):
                // A loop ends inside this buffer: play up to its end, then read from its start again.
                if let loop, time < loop.end - 0.0005, time + Double(buffer.frameLength) / sampleRate >= loop.end - 0.0005 {
                    let keep = AVAudioFrameCount(max(0, ((loop.end - time) * sampleRate).rounded()))
                    reader.seek(to: loop.start)
                    if keep == 0 { continue }
                    if keep < buffer.frameLength {
                        guard let trimmed = OpusReader.slice(buffer, from: 0, count: keep) else { continue }
                        buffer = trimmed
                    }
                }
                let frames = Int64(buffer.frameLength)
                if readerGain != 1, let channels = buffer.floatChannelData {
                    var scale = readerGain
                    for channel in 0 ..< Int(buffer.format.channelCount) {
                        vDSP_vsmul(channels[channel], 1, &scale, channels[channel], 1, vDSP_Length(buffer.frameLength))
                    }
                }
                if awaitingBase {
                    awaitingBase = false
                    lock.withLock {
                        baseTime = time
                        scheduledFrames = 0
                    }
                }
                queuedFrames += frames
                let boundaryFrames = lock.withLock { () -> Int64 in
                    let before = scheduledFrames
                    scheduledFrames += frames
                    return before
                }
                let scheduledGeneration = generation
                let marksTransition = startsNextTrack
                startsNextTrack = false
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async {
                        guard let self, scheduledGeneration == self.generation else { return }
                        self.queuedFrames -= frames
                        if marksTransition { self.completeTransition(boundary: boundaryFrames) }
                        self.pump()
                    }
                }
            case .needMoreData:
                starved = true
                if let download = media?.download, case .failed(let error) = download.state {
                    fail(error.localizedDescription)
                    return
                }
            case .end:
                // Gapless hand-over: keep scheduling straight from the next track's audio.
                if previous == nil, let upcoming = nextMedia, let media,
                   let following = makeReader(for: upcoming, reportFailure: false),
                   following.format.sampleRate == reader.format.sampleRate,
                   following.format.channelCount == reader.format.channelCount {
                    previous = (media, reader)
                    if let observer { media.download?.removeObserver(observer) }
                    observer = nextObserver
                    nextObserver = nil
                    nextMedia = nil
                    self.media = upcoming
                    self.reader = following
                    readerGain = gain(for: upcoming)
                    startsNextTrack = true
                } else {
                    reachedEnd = true
                }
            }
        }
        if previous == nil, let length = reader?.duration, length > 0 {
            lock.withLock { knownDuration = length }
        }
        updatePlayback()
    }

    /// The first buffer of the next track has reached the output: re-base the clock on it.
    private func completeTransition(boundary: Int64) {
        guard previous != nil, let media else { return }
        previous = nil
        let length = reader?.duration ?? 0
        lock.withLock {
            baseTime = -Double(boundary) / sampleRate
            knownDuration = length
        }
        let videoId = media.videoId
        DispatchQueue.main.async { [weak self] in self?.onAdvanced?(videoId) }
    }

    private func updatePlayback() {
        if reachedEnd, queuedFrames <= 0, reader != nil {
            captureTime()
            node.stop()
            lock.withLock {
                nodePlaying = false
                if knownDuration > 0 { lastTime = knownDuration }
            }
            setStatus(.ended)
            DispatchQueue.main.async { [weak self] in self?.onEnded?() }
            return
        }
        let playing = lock.withLock { nodePlaying }
        let hasAudio = queuedFrames > Int64(sampleRate * 0.2) || (reachedEnd && queuedFrames > 0)
        if wantsPlaying {
            if playing {
                if queuedFrames <= 0 {
                    captureTime()
                    node.pause()
                    lock.withLock { nodePlaying = false }
                    setStatus(.buffering)
                } else {
                    setStatus(.ready)
                }
            } else if hasAudio {
                guard startEngine() else { return }
                if let hostTime = startHostTime {
                    startHostTime = nil
                    node.play(at: AVAudioTime(hostTime: hostTime))
                } else {
                    node.play()
                }
                lock.withLock { nodePlaying = true }
                setStatus(.ready)
            } else {
                setStatus(reader == nil ? .loading : .buffering)
            }
        } else {
            if playing {
                captureTime()
                node.pause()
                lock.withLock { nodePlaying = false }
            }
            setStatus(reader == nil ? .loading : .ready)
        }
    }

    private func configure(format: AVAudioFormat) {
        lock.withLock { sampleRate = format.sampleRate }
        guard connectedFormat != format || connectedStretch != wantsStretch else { return }
        if engine.isRunning { engine.stop() }
        if connectedFormat != nil {
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(equalizer)
            engine.disconnectNodeOutput(timePitch)
            engine.disconnectNodeOutput(fader)
            engine.disconnectNodeOutput(delay)
        }
        // The time-stretcher and echo are only in the signal path of a deck that AutoMix is
        // going to mix, so ordinary playback is never processed by them.
        engine.connect(node, to: equalizer, format: format)
        if wantsStretch {
            engine.connect(equalizer, to: timePitch, format: format)
            engine.connect(timePitch, to: fader, format: format)
            engine.connect(fader, to: delay, format: format)
            engine.connect(delay, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(equalizer, to: fader, format: format)
            engine.connect(fader, to: engine.mainMixerNode, format: format)
        }
        connectedFormat = format
        connectedStretch = wantsStretch
        let stretcher = wantsStretch ? timePitch.auAudioUnit.latency : 0
        lock.withLock {
            stretchDelay = stretcher.isFinite ? max(0, stretcher) : 0
            stretchActive = wantsStretch
        }
    }

    private func startEngine() -> Bool {
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                fail("Couldn't start audio output: \(error.localizedDescription)")
                return false
            }
        }
        let outputLatency = engine.outputNode.presentationLatency
        lock.withLock { latency = outputLatency.isFinite ? outputLatency : 0 }
        return true
    }

    /// Loudness normalisation: attenuate tracks mastered louder than YouTube's reference level.
    private func gain(for media: OpenedMedia?) -> Float {
        guard normalize, let loudness = media?.loudnessDb else { return 1 }
        return Float(min(1, pow(10, -loudness / 20)))
    }

    private func captureTime() {
        _ = currentTime
    }

    private func handleConfigurationChange() {
        // The output device changed; the engine has stopped and dropped what was scheduled.
        guard media != nil, reader != nil else { return }
        let position = currentTime
        performSeek(position)
    }

    private func fail(_ message: String) {
        captureTime()
        node.stop()
        lock.withLock { nodePlaying = false }
        setStatus(.failed(message))
    }

    private func setStatus(_ status: Status) {
        guard status != lastStatus else { return }
        lastStatus = status
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }
}
