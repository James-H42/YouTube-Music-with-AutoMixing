import Foundation

/// Counts how often views rebuild; enabled only by `--diagnose`.
enum Diagnostics {
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var counts: [String: Int] = [:]

    static func hit(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
    }
}
