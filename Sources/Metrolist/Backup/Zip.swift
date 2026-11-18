import Compression
import Foundation

/// A small, strict ZIP reader and writer, so backups can be made and opened without running
/// other programs. The reader treats the archive as hostile: names are checked for path
/// traversal, the number and size of entries are capped, declared sizes can't be exceeded,
/// and every entry's CRC is verified.
enum ZipError: LocalizedError {
    case notAZip, unsafeName(String), tooLarge, tooManyEntries, corrupt(String), unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: "That file isn't a ZIP archive."
        case .unsafeName(let name): "The archive contains an unsafe path (\(name)), so it was rejected."
        case .tooLarge: "The archive is larger than the limits allow."
        case .tooManyEntries: "The archive has too many files."
        case .corrupt(let what): "The archive is damaged (\(what))."
        case .unsupported(let what): "The archive uses something unsupported (\(what))."
        }
    }
}

struct ZipLimits {
    var maxEntries = 4_096
    var maxEntryBytes = 512 * 1024 * 1024
    var maxTotalBytes = 600 * 1024 * 1024

    static let backup = ZipLimits(maxEntries: 20_000, maxEntryBytes: 64 * 1024 * 1024, maxTotalBytes: 256 * 1024 * 1024)
}

struct ZipEntry {
    var name: String
    var method: UInt16
    var compressedSize: Int
    var size: Int
    var crc: UInt32
    var offset: Int
    var isDirectory: Bool { name.hasSuffix("/") }
}

enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

struct ZipReader {
    let data: Data
    let entries: [ZipEntry]
    let limits: ZipLimits

    /// True when `name` could escape the folder it is extracted into, or isn't a plain relative path.
    static func isUnsafe(_ name: String) -> Bool {
        if name.isEmpty || name.contains("\0") || name.contains("\\") || name.hasPrefix("/") { return true }
        if name.count >= 2, name.dropFirst().first == ":" { return true }
        return name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." }
    }

    init(data: Data, limits: ZipLimits = ZipLimits()) throws {
        self.data = data
        self.limits = limits
        guard data.count >= 22 else { throw ZipError.notAZip }
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        // The end-of-central-directory record is in the last 64 KB.
        var eocd = -1
        var position = data.count - 22
        while position >= max(0, data.count - 22 - 65_535) {
            if u32(position) == 0x0605_4B50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = u16(eocd + 10)
        let directorySize = u32(eocd + 12)
        let directoryOffset = u32(eocd + 16)
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64") }
        guard count <= limits.maxEntries else { throw ZipError.tooManyEntries }
        guard directoryOffset + directorySize <= data.count else { throw ZipError.corrupt("directory") }
        var parsed: [ZipEntry] = []
        var cursor = directoryOffset
        var total = 0
        var seen = Set<String>()
        for _ in 0 ..< count {
            guard cursor + 46 <= data.count, u32(cursor) == 0x0201_4B50 else { throw ZipError.corrupt("directory entry") }
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let crc = UInt32(u32(cursor + 16)), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            let offset = u32(cursor + 42)
            guard cursor + 46 + nameLength <= data.count else { throw ZipError.corrupt("name") }
            guard flags & 1 == 0 else { throw ZipError.unsupported("encryption") }
            let nameData = data[(data.startIndex + cursor + 46) ..< (data.startIndex + cursor + 46 + nameLength)]
            let name = String(decoding: nameData, as: UTF8.self)
            if Self.isUnsafe(name) { throw ZipError.unsafeName(name) }
            guard seen.insert(name).inserted else { throw ZipError.corrupt("duplicate entry \(name)") }
            guard size <= limits.maxEntryBytes else { throw ZipError.tooLarge }
            total += size
            guard total <= limits.maxTotalBytes else { throw ZipError.tooLarge }
            parsed.append(ZipEntry(name: name, method: UInt16(method), compressedSize: compressed, size: size, crc: crc, offset: offset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        entries = parsed
    }

    /// The contents of one entry, inflated and checked against its CRC.
    func contents(of entry: ZipEntry) throws -> Data {
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard entry.offset + 30 <= data.count, u32(entry.offset) == 0x0403_4B50 else { throw ZipError.corrupt("local header of \(entry.name)") }
        let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt("size of \(entry.name)") }
        let stored = data.subdata(in: (data.startIndex + start) ..< (data.startIndex + start + entry.compressedSize))
        let result: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw ZipError.corrupt("size of \(entry.name)") }
            result = stored
        case 8:
            if entry.size == 0 { result = Data() } else {
                // The buffer is exactly the declared size, so an entry can never inflate past it.
                var output = Data(count: entry.size)
                let written = output.withUnsafeMutableBytes { out in
                    stored.withUnsafeBytes { input in
                        compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, entry.size, input.bindMemory(to: UInt8.self).baseAddress!, stored.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == entry.size else { throw ZipError.corrupt("contents of \(entry.name)") }
                result = output
            }
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard CRC32.checksum(result) == entry.crc else { throw ZipError.corrupt("checksum of \(entry.name)") }
        return result
    }

    func entry(named name: String) -> ZipEntry? { entries.first { $0.name == name } }
}

struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    private static func le(_ value: Int, bytes: Int) -> Data {
        Data((0 ..< bytes).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    mutating func add(_ name: String, _ content: Data, date: Date = Date()) {
        let crc = Int(CRC32.checksum(content))
        var method = 0
        var payload = content
        if content.count > 64 {
            var packed = Data(count: content.count)
            let written = packed.withUnsafeMutableBytes { out in
                content.withUnsafeBytes { input in
                    compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, content.count, input.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0, written < content.count { method = 8; payload = packed.prefix(written) }
        }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: .current, from: date)
        let time = ((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2)
        let day = ((max(1980, parts.year ?? 1980) - 1980) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1)
        let nameData = Data(name.utf8)
        let offset = body.count
        var local = Data()
        local += Self.le(0x0403_4B50, bytes: 4) + Self.le(20, bytes: 2) + Self.le(0x0800, bytes: 2) + Self.le(method, bytes: 2)
        local += Self.le(time, bytes: 2) + Self.le(day, bytes: 2) + Self.le(crc, bytes: 4)
        local += Self.le(payload.count, bytes: 4) + Self.le(content.count, bytes: 4) + Self.le(nameData.count, bytes: 2) + Self.le(0, bytes: 2)
        body += local + nameData + payload
        var central = Data()
        central += Self.le(0x0201_4B50, bytes: 4) + Self.le(20, bytes: 2) + Self.le(20, bytes: 2) + Self.le(0x0800, bytes: 2) + Self.le(method, bytes: 2)
        central += Self.le(time, bytes: 2) + Self.le(day, bytes: 2) + Self.le(crc, bytes: 4)
        central += Self.le(payload.count, bytes: 4) + Self.le(content.count, bytes: 4) + Self.le(nameData.count, bytes: 2)
        central += Self.le(0, bytes: 2) + Self.le(0, bytes: 2) + Self.le(0, bytes: 2) + Self.le(0, bytes: 2) + Self.le(0, bytes: 4) + Self.le(offset, bytes: 4)
        directory += central + nameData
        count += 1
    }

    func finished() -> Data {
        var result = body + directory
        result += Self.le(0x0605_4B50, bytes: 4) + Self.le(0, bytes: 2) + Self.le(0, bytes: 2) + Self.le(count, bytes: 2) + Self.le(count, bytes: 2)
        result += Self.le(directory.count, bytes: 4) + Self.le(body.count, bytes: 4) + Self.le(0, bytes: 2)
        return result
    }
}
