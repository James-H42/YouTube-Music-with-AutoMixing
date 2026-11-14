import Foundation

/// Writes song metadata into a downloaded WebM (Matroska) file: title, artist, album and
/// cover art, as standard Matroska tags that players such as VLC, IINA and mpv display.
///
/// The audio itself is copied untouched. Tags and the cover are inserted ahead of the audio
/// clusters, so the seek index (Cues) is rebuilt with the shifted positions.
enum WebMTagger {
    enum TagError: Error {
        case notMatroska
    }

    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let void: UInt32 = 0xEC
        static let info: UInt32 = 0x1549_A966
        static let tracks: UInt32 = 0x1654_AE6B
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let cluster: UInt32 = 0x1F43_B675
        static let tags: UInt32 = 0x1254_C367
        static let tag: UInt32 = 0x7373
        static let targets: UInt32 = 0x63C0
        static let targetTypeValue: UInt32 = 0x68CA
        static let simpleTag: UInt32 = 0x67C8
        static let tagName: UInt32 = 0x45A3
        static let tagString: UInt32 = 0x4487
        static let attachments: UInt32 = 0x1941_A469
        static let attachedFile: UInt32 = 0x61A7
        static let fileDescription: UInt32 = 0x467E
        static let fileName: UInt32 = 0x466E
        static let fileMimeType: UInt32 = 0x4660
        static let fileData: UInt32 = 0x465C
        static let fileUID: UInt32 = 0x46AE
    }

    /// File name such as "Daft Punk - Get Lucky.webm", safe for the file system.
    static func fileName(for song: Song, extension ext: String) -> String {
        let artist = song.artists.first?.name ?? ""
        var name = artist.isEmpty ? song.title : "\(artist) - \(song.title)"
        name = name.replacingOccurrences(of: #"[/:\\\u{0}]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name = "_" + name }
        if name.isEmpty { name = song.id }
        return String(name.prefix(150)) + "." + ext
    }

    static func tag(source: URL, destination: URL, song: Song, artwork: Data?) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        var position = data.startIndex

        guard let ebml = header(data, at: position), ebml.id == ID.ebml, ebml.size >= 0 else { throw TagError.notMatroska }
        let ebmlEnd = position + ebml.length + Int(ebml.size)
        let ebmlBytes = data[position ..< ebmlEnd]
        position = ebmlEnd

        guard let segment = header(data, at: position), segment.id == ID.segment else { throw TagError.notMatroska }
        let segmentStart = position + segment.length
        position = segmentStart

        // Everything in front of the first audio cluster is small header material.
        var kept = Data()
        var cuePoints: [(time: UInt64, track: UInt64, cluster: UInt64)] = []
        var firstCluster: Int?
        while position < data.endIndex, let element = header(data, at: position) {
            if element.id == ID.cluster {
                firstCluster = position
                break
            }
            guard element.size >= 0 else { throw TagError.notMatroska }
            let end = position + element.length + Int(element.size)
            guard end <= data.endIndex else { throw TagError.notMatroska }
            switch element.id {
            case ID.info, ID.tracks:
                kept.append(data[position ..< end])
            case ID.cues:
                cuePoints = parseCues(data[(position + element.length) ..< end])
            default:
                break // SeekHead, Void and any earlier tags or attachments are dropped.
            }
            position = end
        }
        guard let firstCluster else { throw TagError.notMatroska }
        let oldClusterOffset = firstCluster - segmentStart
        let clusters = data[firstCluster...]

        let tags = tagsElement(for: song)
        let attachment = artwork.map(attachmentsElement) ?? Data()
        // Positions are written as fixed 8-byte integers, so the index's size is known up front.
        let cuesSize = cuesElement(cuePoints, shift: 0).count
        let shift = kept.count + tags.count + attachment.count + cuesSize - oldClusterOffset
        let cues = cuesElement(cuePoints, shift: shift)

        var output = Data(capacity: data.count + tags.count + attachment.count + 256)
        output.append(ebmlBytes)
        output.append(idBytes(ID.segment))
        output.append(sizeBytes(kept.count + tags.count + attachment.count + cues.count + clusters.count))
        output.append(kept)
        output.append(tags)
        output.append(attachment)
        output.append(cues)
        output.append(clusters)
        try output.write(to: destination, options: .atomic)
    }

    // MARK: - Reading

    private struct Header {
        let id: UInt32
        let size: Int64
        let length: Int
    }

    private static func header(_ data: Data, at position: Int) -> Header? {
        guard position < data.endIndex else { return nil }
        let first = data[position]
        guard first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4, position + idLength < data.endIndex else { return nil }
        var id: UInt32 = 0
        for index in 0 ..< idLength { id = (id << 8) | UInt32(data[position + index]) }

        let sizeFirst = data[position + idLength]
        guard sizeFirst != 0 else { return nil }
        let sizeLength = sizeFirst.leadingZeroBitCount + 1
        guard position + idLength + sizeLength <= data.endIndex else { return nil }
        var size = UInt64(sizeFirst) & (0xFF >> UInt64(sizeLength))
        var unknown = size == (0xFF >> UInt64(sizeLength))
        for index in 1 ..< sizeLength {
            let byte = data[position + idLength + index]
            if byte != 0xFF { unknown = false }
            size = (size << 8) | UInt64(byte)
        }
        return Header(id: id, size: unknown ? -1 : Int64(size), length: idLength + sizeLength)
    }

    private static func children(of data: Data, _ body: (UInt32, Data) -> Void) {
        var position = data.startIndex
        while position < data.endIndex, let element = header(data, at: position), element.size >= 0 {
            let start = position + element.length
            let end = start + Int(element.size)
            guard end <= data.endIndex else { return }
            body(element.id, data[start ..< end])
            position = end
        }
    }

    private static func uint(_ data: Data) -> UInt64 {
        data.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func parseCues(_ data: Data) -> [(time: UInt64, track: UInt64, cluster: UInt64)] {
        var points: [(time: UInt64, track: UInt64, cluster: UInt64)] = []
        children(of: data) { id, point in
            guard id == ID.cuePoint else { return }
            var time: UInt64 = 0
            var track: UInt64 = 1
            var cluster: UInt64?
            children(of: point) { id, value in
                if id == ID.cueTime { time = uint(value) }
                if id == ID.cueTrackPositions {
                    children(of: value) { id, value in
                        if id == ID.cueTrack { track = uint(value) }
                        if id == ID.cueClusterPosition { cluster = uint(value) }
                    }
                }
            }
            if let cluster { points.append((time, track, cluster)) }
        }
        return points
    }

    // MARK: - Writing

    private static func idBytes(_ id: UInt32) -> Data {
        var bytes: [UInt8] = []
        var started = false
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((id >> UInt32(shift)) & 0xFF)
            if byte != 0 || started {
                bytes.append(byte)
                started = true
            }
        }
        return Data(bytes)
    }

    /// Element size as an 8-byte EBML integer.
    private static func sizeBytes(_ size: Int) -> Data {
        var bytes: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { bytes.append(UInt8((UInt64(size) >> UInt64(shift)) & 0xFF)) }
        return Data(bytes)
    }

    private static func element(_ id: UInt32, _ payload: Data) -> Data {
        idBytes(id) + sizeBytes(payload.count) + payload
    }

    private static func uintElement(_ id: UInt32, _ value: UInt64, width: Int? = nil) -> Data {
        var bytes: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        let leadingZeros = bytes.firstIndex(where: { $0 != 0 }) ?? 7
        let count = width ?? max(1, 8 - leadingZeros)
        return element(id, Data(bytes.suffix(count)))
    }

    private static func stringElement(_ id: UInt32, _ value: String) -> Data {
        element(id, Data(value.utf8))
    }

    private static func cuesElement(_ points: [(time: UInt64, track: UInt64, cluster: UInt64)], shift: Int) -> Data {
        guard !points.isEmpty else { return Data() }
        var payload = Data()
        for point in points {
            let positions = uintElement(ID.cueTrack, point.track)
                + uintElement(ID.cueClusterPosition, UInt64(Int(point.cluster) + shift), width: 8)
            payload += element(ID.cuePoint, uintElement(ID.cueTime, point.time) + element(ID.cueTrackPositions, positions))
        }
        return element(ID.cues, payload)
    }

    private static func tagsElement(for song: Song) -> Data {
        var fields: [(String, String)] = [("TITLE", song.title)]
        if !song.artists.isEmpty { fields.append(("ARTIST", song.artists.map(\.name).joined(separator: ", "))) }
        if let album = song.album?.name, !album.isEmpty { fields.append(("ALBUM", album)) }
        fields.append(("COMMENT", "https://music.youtube.com/watch?v=\(song.id)"))

        // Target type 30 is "track"; players read these as the song's own tags.
        var payload = element(ID.targets, uintElement(ID.targetTypeValue, 30))
        for (name, value) in fields {
            payload += element(ID.simpleTag, stringElement(ID.tagName, name) + stringElement(ID.tagString, value))
        }
        return element(ID.tags, element(ID.tag, payload))
    }

    private static func attachmentsElement(_ image: Data) -> Data {
        let isPNG = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let file = stringElement(ID.fileDescription, "Cover")
            + stringElement(ID.fileName, isPNG ? "cover.png" : "cover.jpg")
            + stringElement(ID.fileMimeType, isPNG ? "image/png" : "image/jpeg")
            + element(ID.fileData, image)
            + uintElement(ID.fileUID, UInt64.random(in: 1 ... UInt64(Int64.max)), width: 8)
        return element(ID.attachments, element(ID.attachedFile, file))
    }
}
