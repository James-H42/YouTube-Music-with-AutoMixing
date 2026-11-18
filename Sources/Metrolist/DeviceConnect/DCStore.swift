import Foundation

/// Paired devices. The pair secret never leaves the Keychain; the list of device ids is the
/// only thing kept beside it, and it holds no secrets. Forgetting a device deletes its item.
/// `prefix` keeps separate lists: your own devices ("deviceconnect"), shared-queue guests
/// ("sharedqueue.guest") and shared queues this Mac has joined ("sharedqueue.joined").
final class DCKeychainPairStore: DCPairStore, @unchecked Sendable {
    private let prefix: String
    private let indexAccount: String
    private let lock = NSLock()

    init(prefix: String = "deviceconnect") {
        self.prefix = prefix
        indexAccount = "\(prefix).index"
    }

    private func account(_ id: String) -> String { "\(prefix).pair.\(id)" }

    var ids: [String] {
        lock.withLock {
            guard let text = Keychain.get(indexAccount), let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else { return [] }
            return list
        }
    }

    func all() -> [DCPair] { ids.compactMap { load($0) } }

    private func load(_ id: String) -> DCPair? {
        guard let text = Keychain.get(account(id)) else { return nil }
        return try? JSONDecoder().decode(DCPair.self, from: Data(text.utf8))
    }

    func find(peerId: String, fingerprint: String, anonymous: Bool) -> DCPair? {
        guard dcIsValidDeviceId(peerId), let pair = lock.withLock({ load(peerId) }) else { return nil }
        return pair.fingerprint == fingerprint && pair.anonymous == anonymous ? pair : nil
    }

    func save(_ pair: DCPair) -> Bool {
        guard dcIsValidDeviceId(pair.peerId), pair.secret.count == 32, let data = try? JSONEncoder().encode(pair) else { return false }
        return lock.withLock {
            guard Keychain.set(String(decoding: data, as: UTF8.self), for: account(pair.peerId)) else { return false }
            var list = (Keychain.get(indexAccount).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? []
            if !list.contains(pair.peerId) { list.append(pair.peerId) }
            return Keychain.set(String(decoding: (try? JSONEncoder().encode(list)) ?? Data(), as: UTF8.self), for: indexAccount)
        }
    }

    func updateMetadata(peerId: String, name: String, model: String) {
        lock.withLock {
            guard var pair = load(peerId) else { return }
            pair.peerName = name
            pair.peerModel = model
            if let data = try? JSONEncoder().encode(pair) { Keychain.set(String(decoding: data, as: UTF8.self), for: account(peerId)) }
        }
    }

    func forget(_ peerId: String) {
        lock.withLock {
            Keychain.set(nil, for: account(peerId))
            var list = (Keychain.get(indexAccount).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? []
            list.removeAll { $0 == peerId }
            Keychain.set(String(decoding: (try? JSONEncoder().encode(list)) ?? Data(), as: UTF8.self), for: indexAccount)
        }
    }

    func forgetAll() { for id in ids { forget(id) } }
}

/// An in-memory store for tests.
final class DCMemoryPairStore: DCPairStore {
    var pairs: [String: DCPair] = [:]
    func find(peerId: String, fingerprint: String, anonymous: Bool) -> DCPair? {
        pairs[peerId].flatMap { $0.fingerprint == fingerprint && $0.anonymous == anonymous ? $0 : nil }
    }
    func save(_ pair: DCPair) -> Bool { pairs[pair.peerId] = pair; return true }
}

/// Which peers may connect at all: the same private and local ranges Metrolist allows.
enum DCAddress {
    static func isLAN(_ host: String) -> Bool {
        let base = host.split(separator: "%").first.map(String.init) ?? host
        let parts = base.split(separator: ".")
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]), parts.allSatisfy({ Int($0) != nil }) {
            return a == 10 || (a == 172 && (16 ... 31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64 ... 127).contains(b))
        }
        guard base.contains(":") else { return false }
        // IPv4-mapped addresses are judged as the IPv4 address they hold.
        if base.lowercased().hasPrefix("::ffff:"), let v4 = base.split(separator: ":").last { return isLAN(String(v4)) }
        guard let first = base.split(separator: ":", omittingEmptySubsequences: false).first, let value = Int(first.isEmpty ? "0" : String(first), radix: 16) else { return false }
        return value & 0xFE00 == 0xFC00 || value & 0xFFC0 == 0xFE80
    }
}
