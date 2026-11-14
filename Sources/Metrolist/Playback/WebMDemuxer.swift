import Foundation

/// A random-access byte source that may still be growing (a progressive download).
protocol ByteSource: AnyObject {
    /// Length of the contiguous prefix that can be read right now.
    var availableBytes: Int64 { get }
    /// Final size once known.
    var totalBytes: Int64? { get }
    /// Returns nil when the requested range is not fully available yet.
    func read(offset: Int64, length: Int) -> Data?
}

/// Minimal progressive WebM (Matroska) demuxer for a single audio track.
/// YouTube's audio-only WebM files carry one Opus packet per SimpleBlock and a Cues index up front.
final class WebMDemuxer {
    struct Packet {
        let data: Data
        let timeNs: Int64
        /// Encoder padding at the end of this packet that must not be played.
        var discardPaddingNs: Int64 = 0
    }

    struct TrackInfo {
        var codecID = ""
        var sampleRate: Double = 48_000
        var channels = 2
        var codecPrivate: Data?
        var codecDelayNs: Int64 = 0
        var seekPreRollNs: Int64 = 80_000_000
    }

    enum ReadResult {
        case packet(Packet)
        case needMoreData
        case endOfStream
    }

    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let info: UInt32 = 0x1549_A966
        static let timecodeScale: UInt32 = 0x2A_D7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let codecDelay: UInt32 = 0x56AA
        static let seekPreRoll: UInt32 = 0x56BB
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueClusterPosition: UInt32 = 0xF1
        static let cluster: UInt32 = 0x1F43_B675
        static let timecode: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let discardPadding: UInt32 = 0x75A2
    }

    private static let unknownSize: Int64 = -1

    private let source: ByteSource
    private(set) var track: TrackInfo?
    private(set) var durationSeconds: Double?

    private var timecodeScale: Int64 = 1_000_000
    private var segmentDataStart: Int64 = 0
    private var firstClusterOffset: Int64?
    private var cues: [(timeNs: Int64, clusterPosition: Int64)] = []
    private var offset: Int64 = 0
    private var clusterTimecode: Int64 = 0

    init(source: ByteSource) {
        self.source = source
    }

    /// True once track info has been parsed and packets can be decoded.
    var isReady: Bool { track != nil && firstClusterOffset != nil }

    /// Positions the reader on the cluster containing `seconds` (or the closest one before it).
    func seek(to seconds: Double) {
        let targetNs = Int64(max(0, seconds) * 1_000_000_000)
        if let cue = cues.last(where: { $0.timeNs <= targetNs }) {
            offset = segmentDataStart + cue.clusterPosition
        } else if let first = firstClusterOffset {
            offset = first
        }
    }

    func next() -> ReadResult {
        while true {
            guard let header = readHeader(at: offset) else {
                if let total = source.totalBytes, offset >= total { return .endOfStream }
                return .needMoreData
            }
            let payloadStart = offset + Int64(header.length)

            switch header.id {
            case ID.segment:
                segmentDataStart = payloadStart
                offset = payloadStart

            case ID.cluster:
                if firstClusterOffset == nil { firstClusterOffset = offset }
                offset = payloadStart

            case ID.blockGroup:
                guard let payload = payload(header, at: payloadStart) else { return .needMoreData }
                offset = payloadStart + header.size
                var packet: Packet?
                var padding: Int64 = 0
                Self.forEachChild(of: payload) { id, value in
                    if id == ID.block { packet = parseBlock(value) }
                    if id == ID.discardPadding { padding = Int64(Self.uint(value)) }
                }
                if var packet {
                    packet.discardPaddingNs = max(0, padding)
                    return .packet(packet)
                }

            case ID.timecode:
                guard let payload = payload(header, at: payloadStart) else { return .needMoreData }
                clusterTimecode = Int64(Self.uint(payload))
                offset = payloadStart + header.size

            case ID.simpleBlock, ID.block:
                guard let payload = payload(header, at: payloadStart) else { return .needMoreData }
                offset = payloadStart + header.size
                if let packet = parseBlock(payload) { return .packet(packet) }

            case ID.info:
                guard let payload = payload(header, at: payloadStart) else { return .needMoreData }
                parseInfo(payload)
                offset = payloadStart + header.size

            case ID.tracks:
                guard let payload = payload(header, at: payloadStart) else { return .needMoreData }
                parseTracks(payload)
                offset = payloadStart + header.size

            case ID.cues:
                guard let payload = payload(header, at: payloadStart) else { return .needMoreData }
                parseCues(payload)
                offset = payloadStart + header.size

            default:
                if header.size == Self.unknownSize { return .endOfStream }
                offset = payloadStart + header.size
            }
        }
    }

    // MARK: - Element parsing

    private struct Header {
        let id: UInt32
        let size: Int64
        let length: Int
    }

    private func readHeader(at position: Int64) -> Header? {
        let wanted = 12
        let available = Int(min(Int64(wanted), source.availableBytes - position))
        guard available >= 2, let bytes = source.read(offset: position, length: available) else { return nil }
        return Self.parseHeader(bytes)
    }

    private func payload(_ header: Header, at position: Int64) -> Data? {
        guard header.size >= 0, header.size < 64 * 1024 * 1024 else { return nil }
        if header.size == 0 { return Data() }
        return source.read(offset: position, length: Int(header.size))
    }

    private static func parseHeader(_ bytes: Data) -> Header? {
        let b = [UInt8](bytes)
        guard let first = b.first, first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, b.count > idLength else { return nil }
        var id: UInt32 = 0
        for i in 0 ..< idLength { id = (id << 8) | UInt32(b[i]) }

        let sizeFirst = b[idLength]
        guard sizeFirst != 0 else { return nil }
        let sizeLength = sizeFirst.leadingZeroBitCount + 1
        guard b.count >= idLength + sizeLength else { return nil }
        var size = UInt64(sizeFirst) & (0xFF >> UInt64(sizeLength))
        var allOnes = size == (0xFF >> UInt64(sizeLength))
        for i in 1 ..< sizeLength {
            let byte = b[idLength + i]
            if byte != 0xFF { allOnes = false }
            size = (size << 8) | UInt64(byte)
        }
        return Header(id: id, size: allOnes ? unknownSize : Int64(size), length: idLength + sizeLength)
    }

    /// Walks the direct children of a fully loaded master element.
    private static func forEachChild(of data: Data, _ body: (UInt32, Data) -> Void) {
        var position = data.startIndex
        while position < data.endIndex {
            guard let header = parseHeader(data[position...].prefix(12)), header.size >= 0 else { return }
            let start = position + header.length
            let end = start + Int(header.size)
            guard end <= data.endIndex else { return }
            body(header.id, data[start ..< end])
            position = end
        }
    }

    private static func uint(_ data: Data) -> UInt64 {
        data.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func float(_ data: Data) -> Double {
        switch data.count {
        case 4: return Double(Float(bitPattern: UInt32(uint(data))))
        case 8: return Double(bitPattern: uint(data))
        default: return 0
        }
    }

    private func parseInfo(_ data: Data) {
        var rawDuration: Double?
        Self.forEachChild(of: data) { id, value in
            switch id {
            case ID.timecodeScale: timecodeScale = Int64(Self.uint(value))
            case ID.duration: rawDuration = Self.float(value)
            default: break
            }
        }
        if let rawDuration {
            durationSeconds = rawDuration * Double(timecodeScale) / 1_000_000_000
        }
    }

    private func parseTracks(_ data: Data) {
        Self.forEachChild(of: data) { id, entry in
            guard id == ID.trackEntry, track == nil else { return }
            var info = TrackInfo()
            var isAudio = false
            Self.forEachChild(of: entry) { id, value in
                switch id {
                case ID.codecID: info.codecID = String(decoding: value, as: UTF8.self)
                case ID.codecPrivate: info.codecPrivate = Data(value)
                case ID.codecDelay: info.codecDelayNs = Int64(Self.uint(value))
                case ID.seekPreRoll: info.seekPreRollNs = Int64(Self.uint(value))
                case ID.audio:
                    isAudio = true
                    Self.forEachChild(of: value) { id, value in
                        switch id {
                        case ID.samplingFrequency: info.sampleRate = Self.float(value)
                        case ID.channels: info.channels = Int(Self.uint(value))
                        default: break
                        }
                    }
                default: break
                }
            }
            if isAudio { track = info }
        }
    }

    private func parseCues(_ data: Data) {
        var parsed: [(Int64, Int64)] = []
        Self.forEachChild(of: data) { id, point in
            guard id == ID.cuePoint else { return }
            var time: Int64 = 0
            var position: Int64?
            Self.forEachChild(of: point) { id, value in
                switch id {
                case ID.cueTime: time = Int64(Self.uint(value))
                case ID.cueTrackPositions:
                    Self.forEachChild(of: value) { id, value in
                        if id == ID.cueClusterPosition { position = Int64(Self.uint(value)) }
                    }
                default: break
                }
            }
            if let position { parsed.append((time * timecodeScale, position)) }
        }
        cues = parsed.sorted { $0.0 < $1.0 }.map { (timeNs: $0.0, clusterPosition: $0.1) }
    }

    private func parseBlock(_ data: Data) -> Packet? {
        let b = data
        guard let first = b.first, first != 0 else { return nil }
        let trackLength = first.leadingZeroBitCount + 1
        guard b.count > trackLength + 3 else { return nil }
        let base = b.startIndex + trackLength
        let relative = Int16(bitPattern: UInt16(b[base]) << 8 | UInt16(b[base + 1]))
        let timeNs = (clusterTimecode + Int64(relative)) * timecodeScale
        return Packet(data: Data(b[(base + 3)...]), timeNs: timeNs)
    }
}
