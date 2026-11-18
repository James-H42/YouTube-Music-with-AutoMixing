import Darwin
import Foundation
import Observation

/// What guests of a shared queue may do, and who added what. `DCTarget` asks it before acting
/// on a guest's command. See `docs/Shared queue design.md`.
@MainActor
@Observable
final class SharedQueuePolicy {
    static let maxPerRequest = 10
    static let maxWaiting = 20
    static let maxPerWindow = 30
    static let window: TimeInterval = 10 * 60

    /// Off by default, as in Spotify's Jam: guests only add songs.
    var guestsCanControl: Bool {
        didSet { if persists { UserDefaults.standard.set(guestsCanControl, forKey: "sharedQueueGuestsControl") } }
    }
    /// Lets phones signed in to their own YouTube account join (off by default). Their phone
    /// will then say this Mac "uses the same account", which isn't so; see `DCSession.mirrorPeerAccount`.
    var allowSignedInGuests: Bool {
        didSet { if persists { UserDefaults.standard.set(allowSignedInGuests, forKey: "sharedQueueSignedInGuests") } }
    }
    /// Whether guests are admitted at all (a shared queue is running).
    var open = false
    /// Song id → the guest (peer key) who added it, while it is in the queue.
    private(set) var addedBy: [String: String] = [:]
    @ObservationIgnored private var recent: [String: [Date]] = [:]
    @ObservationIgnored private let persists: Bool

    init(persisting: Bool = true) {
        persists = persisting
        guestsCanControl = persisting && UserDefaults.standard.bool(forKey: "sharedQueueGuestsControl")
        allowSignedInGuests = persisting && UserDefaults.standard.bool(forKey: "sharedQueueSignedInGuests")
    }

    func contributor(of songId: String) -> String? { addedBy[songId] }

    func added(by guest: String) -> Int { addedBy.values.filter { $0 == guest }.count }

    /// Why this guest may not add `count` more songs now (an error code for the phone), or nil.
    /// `waiting` is how many of their songs are still to play.
    func refusal(guest: String, count: Int, waiting: Int, now: Date = Date()) -> String? {
        guard open else { return "NOT_ALLOWED" }
        guard count <= Self.maxPerRequest else { return "TOO_LARGE" }
        guard waiting + count <= Self.maxWaiting else { return "NOT_ALLOWED" }
        let lately = (recent[guest] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard lately.count + count <= Self.maxPerWindow else { return "NOT_ALLOWED" }
        return nil
    }

    func record(guest: String, songIds: [String], now: Date = Date()) {
        recent[guest] = (recent[guest] ?? []).filter { now.timeIntervalSince($0) < Self.window } + songIds.map { _ in now }
        for id in songIds { addedBy[id] = guest }
    }

    /// Forgets who added songs that have left the queue.
    func prune(keeping ids: Set<String>) {
        if addedBy.keys.contains(where: { !ids.contains($0) }) { addedBy = addedBy.filter { ids.contains($0.key) } }
    }

    func forgetGuest(_ guest: String) {
        recent[guest] = nil
    }

    func reset() {
        addedBy = [:]
        recent = [:]
    }
}

/// The shared queue as the person running it sees it: start, let people join, end.
@MainActor
@Observable
final class SharedQueue {
    static let shared = SharedQueue()
    let policy = SharedQueuePolicy()

    var isRunning: Bool { DeviceConnect.guests.enabled }

    /// Starts listening for guests and opens joining for five minutes.
    func start() {
        policy.open = true
        DeviceConnect.guests.enabled = true
        DeviceConnect.guests.openPairing()
    }

    /// Ends it for everyone: guests are disconnected and nothing listens for them any more.
    /// Remembered guests can rejoin without a code the next time one is started.
    func end() {
        policy.open = false
        DeviceConnect.guests.enabled = false
        DeviceConnect.guests.closePairing()
        policy.reset()
    }

    func remove(guest peerId: String) {
        policy.forgetGuest(DeviceConnect.guests.peerKey(peerId))
        DeviceConnect.guests.forget(peerId)
    }

    /// "Added by …" for a song in the queue, when a guest added it.
    func addedByName(_ songId: String) -> String? {
        guard let key = policy.contributor(of: songId), key.hasPrefix(DeviceConnect.guestPrefix) else { return nil }
        let id = String(key.dropFirst(DeviceConnect.guestPrefix.count))
        return DeviceConnect.guests.paired.first { $0.id == id }?.name ?? "a guest"
    }

    /// This Mac's private-range IPv4 addresses, for guests whose network blocks discovery.
    static func lanAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if DCAddress.isLAN(text), !result.contains(text) { result.append(text) }
        }
        return result
    }
}
