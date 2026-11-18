import Foundation

/// The Mac as the audible target of Device Connect: a paired phone is the remote, this app
/// plays. The phone's commands go through `PlayerController` like the Mac's own controls, so
/// AutoMix, the equaliser and scrobbling behave exactly as they do locally.
///
/// Follows the target half of Metrolist's playback protocol (version 4, "legacy" timing: no
/// shared clock, one-second progress updates; `DeviceConnectRemote.kt`). Only what a remote
/// can ask for is accepted: transport, volume, repeat, shuffle and queue edits. Nothing here
/// reads or writes files, settings, history or accounts.
@MainActor
final class DCTarget {
    static let maxQueue = 1_000
    typealias JSONObject = [String: Any]

    private let player: PlayerController
    /// The rules for shared-queue guests (peers whose key starts with `DeviceConnect.guestPrefix`).
    /// With none, guests are refused everything.
    var guestPolicy: SharedQueuePolicy?
    /// Sends one playback message (already a JSON object) to a peer. Set by the manager.
    var send: (_ peerId: String, _ message: JSONObject) -> Bool = { _, _ in false }
    private(set) var controllers: Set<String> = []
    private var sessionId: String?
    private var revision: Int64 = 0, queueRevision: Int64 = 0, trackRevision: Int64 = 0
    private var queueStateId = ""
    private var items: [JSONObject] = []
    private var original: [JSONObject] = []
    private var originalIndices: [Int] = []
    private var isShuffled = false
    private var title: String?
    private var finite = true
    private var raw: [String: JSONObject] = [:]
    private var timer: Timer?
    private var lastSentPosition = -1.0
    private var lastPlaying = false
    private var lastSettings = ""

    init(player: PlayerController) { self.player = player }

    // MARK: Peers

    func peerDisconnected(_ peerId: String) {
        controllers.remove(peerId)
        if controllers.isEmpty { endSession() }
    }

    func stop() {
        controllers.removeAll()
        endSession()
    }

    /// Lets go of one kind of peer (guests when the shared queue ends, your own devices when
    /// Device Connect is switched off) without disturbing the other.
    func stop(guests: Bool) {
        controllers = controllers.filter { Self.isGuest($0) != guests }
        if controllers.isEmpty { endSession() }
    }

    static func isGuest(_ key: String) -> Bool { key.hasPrefix(DeviceConnect.guestPrefix) }

    private func endSession() {
        sessionId = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: Messages in

    func receive(_ data: Data, from peerId: String) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject, let type = message["type"] as? String else {
            return sendError(peerId, "INVALID_MESSAGE")
        }
        if Self.isGuest(peerId) {
            guard guestPolicy?.open == true else { return sendError(peerId, "NOT_ALLOWED") }
            switch type {
            // A guest's phone hands over its own queue when its queue isn't empty. The shared
            // queue is not replaced: the guest is sent it and follows it instead.
            case "ATTACH", "TRANSFER": return attach(peerId)
            case "PULL": return sendError(peerId, "NOT_ALLOWED")
            case "RELEASE":
                guard controllers.contains(peerId) else { return }
                controllers.remove(peerId)
                if controllers.isEmpty { endSession() }
                return
            default: break
            }
        }
        switch type {
        case "ATTACH": attach(peerId)
        case "TRANSFER": transfer(peerId, message)
        case "PULL": pull(peerId, message)
        case "RELEASE": release(peerId, message)
        case "COMMAND": command(peerId, message)
        case "STATE", "UPDATE", "ERROR": break // those are for a controller; this app is never one
        default: sendError(peerId, "INVALID_MESSAGE")
        }
    }

    private func attach(_ peerId: String) {
        if sessionId == nil { startSession() }
        controllers.insert(peerId)
        startTimer()
        sendState(to: peerId)
    }

    private func startSession() {
        sessionId = Self.newId()
        revision = 1; queueRevision = 1; trackRevision = 1
        queueStateId = Self.newId()
        adoptPlayerQueue()
    }

    private func transfer(_ peerId: String, _ message: JSONObject) {
        guard let snapshot = message["snapshot"] as? JSONObject, let playback = snapshot["playback"] as? JSONObject,
              let queue = playback["queue"] as? JSONObject, let displayed = queue["displayedItems"] as? [JSONObject]
        else { return sendError(peerId, "INVALID_MESSAGE") }
        guard let error = validate(displayed) else {
            let index = (queue["currentIndex"] as? Int) ?? -1
            guard index >= -1, index < displayed.count else { return sendError(peerId, "INVALID_MESSAGE") }
            if sessionId == nil { sessionId = (snapshot["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.newId() }
            remember(displayed)
            items = displayed
            original = (queue["originalItems"] as? [JSONObject]) ?? displayed
            originalIndices = (queue["originalIndices"] as? [Int]) ?? []
            isShuffled = (queue["isShuffled"] as? Bool) ?? false
            if !isShuffled || original.count != items.count { original = items; originalIndices = Array(items.indices); isShuffled = false }
            title = playback["title"] as? String
            finite = (playback["finite"] as? Bool) ?? true
            revision += 1; queueRevision += 1; trackRevision += 1
            queueStateId = Self.newId()
            controllers.insert(peerId)
            apply(index: index, position: Double((playback["positionMs"] as? Int64) ?? Int64((playback["positionMs"] as? Double) ?? 0)) / 1000,
                  playing: (playback["playing"] as? Bool) ?? false, restart: true)
            if let mode = playback["repeatMode"] as? String { player.repeatMode = Self.repeatMode(mode) }
            startTimer()
            broadcastState()
            return
        }
        sendError(peerId, error)
    }

    private func pull(_ peerId: String, _ message: JSONObject) {
        guard controllers.contains(peerId), message["sessionId"] as? String == sessionId else { return }
        syncFromPlayer()
        var handoff = snapshot()
        handoff["sessionId"] = sessionId
        _ = send(peerId, ["type": "TRANSFER", "sessionId": sessionId as Any, "snapshot": handoff])
        controllers.remove(peerId)
        for other in controllers { _ = send(other, ["type": "RELEASE", "sessionId": sessionId as Any]) }
        controllers.removeAll()
        player.pause()
        endSession()
    }

    private func release(_ peerId: String, _ message: JSONObject) {
        guard message["sessionId"] as? String == sessionId, controllers.contains(peerId) else { return }
        controllers.remove(peerId)
        if (message["pause"] as? Bool) == true { player.pause() }
        if controllers.isEmpty { endSession() }
    }

    // MARK: Commands

    private func command(_ peerId: String, _ message: JSONObject) {
        guard controllers.contains(peerId), message["sessionId"] as? String == sessionId, let command = message["command"] as? JSONObject,
              let action = command["action"] as? String
        else { return }
        // A guest asking for something guests can never do is told so whatever the queue revision.
        if Self.isGuest(peerId) {
            var allowed: Set<String> = ["ADD", "PLAY_NEXT", "REPLACE_QUEUE", "REMOVE"]
            if guestPolicy?.guestsCanControl == true { allowed.formUnion(["PLAY", "PAUSE", "NEXT", "PREVIOUS", "VOLUME", "REPEAT"]) }
            guard allowed.contains(action), guestPolicy != nil else { return sendError(peerId, "NOT_ALLOWED") }
        }
        syncFromPlayer()
        let indexed: Set<String> = ["SELECT", "REMOVE", "MOVE", "REORDER", "RESTORE_QUEUE", "REPLACE_CURRENT"]
        let expected = (message["queueRevision"] as? Int64) ?? Int64((message["queueRevision"] as? Int) ?? -1)
        if indexed.contains(action), expected != queueRevision {
            sendError(peerId, "STALE_QUEUE")
            sendState(to: peerId)
            return
        }
        let before = items.map { $0["id"] as? String ?? "" }
        let beforeIndex = currentIndex
        var trackChanged = false, seek = false
        func int(_ key: String, _ fallback: Int = -1) -> Int { (command[key] as? Int) ?? fallback }

        if Self.isGuest(peerId) {
            guard let policy = guestPolicy else { return sendError(peerId, "NOT_ALLOWED") }
            switch action {
            case "ADD", "PLAY_NEXT":
                guard let songs = command["songs"] as? [JSONObject], !songs.isEmpty else { return fail(peerId) }
                if let error = guestAdd(peerId, songs, policy) { return sendError(peerId, error) }
                return finish(before: before, beforeIndex: beforeIndex, trackChanged: false, seek: false)
            case "REPLACE_QUEUE":
                // The guest tapped a song to play it: in a shared queue that means "add this one".
                guard let songs = command["songs"] as? [JSONObject], songs.indices.contains(int("index")) else { return fail(peerId) }
                if let error = guestAdd(peerId, [songs[int("index")]], policy) { return sendError(peerId, error) }
                return finish(before: before, beforeIndex: beforeIndex, trackChanged: false, seek: false)
            case "REMOVE":
                // Only songs this guest added, and only ones still to come.
                let indices = Set((command["indices"] as? [Int]) ?? []).union((command["indices"] as? [Int])?.isEmpty == false ? [] : [int("index")])
                guard !indices.isEmpty, indices.allSatisfy({ items.indices.contains($0) && $0 > currentIndex
                    && policy.contributor(of: items[$0]["id"] as? String ?? "") == peerId }) else { return sendError(peerId, "NOT_ALLOWED") }
            case "PLAY", "PAUSE", "NEXT", "PREVIOUS", "VOLUME", "REPEAT":
                guard policy.guestsCanControl else { return sendError(peerId, "NOT_ALLOWED") }
            default:
                return sendError(peerId, "NOT_ALLOWED")
            }
        }
        let positionMs = (command["positionMs"] as? Int64) ?? Int64((command["positionMs"] as? Double) ?? Double((command["positionMs"] as? Int) ?? 0))

        func select(_ index: Int, position: Double = 0) {
            apply(index: index, position: position, playing: true, restart: true)
            trackChanged = true; seek = true
        }

        switch action {
        case "PLAY":
            guard currentIndex >= 0 else { return fail(peerId) }
            player.play()
        case "PAUSE": player.pause()
        case "SEEK":
            guard positionMs >= 0, currentIndex >= 0 else { return fail(peerId) }
            player.seek(to: Double(positionMs) / 1000)
            seek = true
        case "VOLUME":
            guard let volume = (command["volume"] as? NSNumber)?.doubleValue, (0 ... 1).contains(volume) else { return fail(peerId) }
            player.volume = volume
        case "REPEAT":
            if let mode = command["repeatMode"] as? String { player.repeatMode = Self.repeatMode(mode) } else { player.cycleRepeat() }
        case "NEXT":
            if currentIndex + 1 < items.count { select(currentIndex + 1) }
            else if player.repeatMode == .all, !items.isEmpty { select(0) }
            else { player.pause() }
        case "PREVIOUS":
            guard currentIndex >= 0 else { return fail(peerId) }
            if player.currentTime > 3 { player.seek(to: 0); seek = true } else { select(max(0, currentIndex - 1)) }
        case "SELECT":
            let index = int("index"), to = int("toIndex")
            guard items.indices.contains(index), positionMs >= 0, to >= -1, to < items.count else { return fail(peerId) }
            var target = index
            if to >= 0 { move(index, to); target = to }
            select(target, position: Double(positionMs) / 1000)
        case "REPLACE_QUEUE":
            guard let songs = command["songs"] as? [JSONObject], !songs.isEmpty, songs.indices.contains(int("index")), positionMs >= 0 else { return fail(peerId) }
            if let error = validate(songs) { return sendError(peerId, error) }
            remember(songs)
            let keep = (command["preserveCurrentTrack"] as? Bool) == true && player.currentSong?.id == (songs[int("index")]["id"] as? String)
            items = songs
            original = songs; originalIndices = Array(songs.indices); isShuffled = false
            title = command["title"] as? String
            finite = (command["finite"] as? Bool) ?? true
            if keep {
                apply(index: int("index"), position: 0, playing: player.isPlaying, restart: false)
            } else {
                select(int("index"), position: Double(positionMs) / 1000)
            }
            trackChanged = !keep
            if (command["enabled"] as? Bool) == true { shuffleQueue() }
        case "ADD", "PLAY_NEXT":
            guard let songs = command["songs"] as? [JSONObject], !songs.isEmpty else { return fail(peerId) }
            if let error = validate(items + songs) { return sendError(peerId, error) }
            remember(songs)
            // Play Next goes where the Mac's own Play Next goes (after a song already fading in).
            if action == "ADD" { items += songs } else { items.insert(contentsOf: songs, at: min(items.count, max(currentIndex + 1, player.playNextIndex))) }
            resetOriginal()
            apply(index: currentIndex, position: 0, playing: player.isPlaying, restart: false)
            player.markQueuedByHand(songs.compactMap { $0["id"] as? String }, playNext: action == "PLAY_NEXT")
        case "REMOVE":
            let indices = Set((command["indices"] as? [Int]) ?? []).union((command["indices"] as? [Int])?.isEmpty == false ? [] : [int("index")])
            guard !indices.isEmpty, indices.allSatisfy({ items.indices.contains($0) }) else { return fail(peerId) }
            let removingCurrent = indices.contains(currentIndex)
            let currentId = currentIndex >= 0 ? items[currentIndex]["id"] as? String : nil
            let removedBefore = indices.filter { $0 < currentIndex }.count
            items = items.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            resetOriginal()
            if removingCurrent {
                let next = min(max(0, currentIndex - removedBefore), items.count - 1)
                if items.isEmpty { apply(index: -1, position: 0, playing: false, restart: true) } else { apply(index: next, position: 0, playing: player.isPlaying, restart: true) }
                trackChanged = true; seek = true
            } else {
                apply(index: currentIndex - removedBefore, position: 0, playing: player.isPlaying, restart: false)
            }
            _ = currentId
        case "MOVE":
            let from = int("index"), to = int("toIndex")
            guard items.indices.contains(from), items.indices.contains(to) else { return fail(peerId) }
            let currentId = currentItemId
            move(from, to)
            resetOriginal()
            apply(index: indexOf(currentId), position: 0, playing: player.isPlaying, restart: false)
        case "REORDER":
            guard let order = command["order"] as? [Int], order.count == items.count, Set(order) == Set(items.indices) else { return fail(peerId) }
            let currentId = currentItemId
            items = order.map { items[$0] }
            resetOriginal()
            apply(index: indexOf(currentId), position: 0, playing: player.isPlaying, restart: false)
        case "CLEAR":
            items = []; resetOriginal(); title = nil
            apply(index: -1, position: 0, playing: false, restart: true)
            trackChanged = true
        case "SHUFFLE":
            let want = (command["enabled"] as? Bool) ?? !isShuffled
            if want != isShuffled { want ? shuffleQueue() : unshuffleQueue() }
        default:
            // SPEED, PITCH, REPLACE_CURRENT and RESTORE_QUEUE are not supported by this target.
            return fail(peerId)
        }
        finish(before: before, beforeIndex: beforeIndex, trackChanged: trackChanged, seek: seek)
    }

    /// Moves the revisions on after a command and tells every controller.
    private func finish(before: [String], beforeIndex: Int, trackChanged: Bool, seek: Bool) {
        let ids = items.map { $0["id"] as? String ?? "" }
        let queueChanged = ids != before
        revision += 1
        if queueChanged { queueRevision += 1; queueStateId = Self.newId() }
        if trackChanged || beforeIndex != currentIndex { trackRevision += 1 }
        guestPolicy?.prune(keeping: Set(ids))
        if queueChanged || trackChanged { broadcastState() } else { broadcastUpdate(seek: seek) }
    }

    // MARK: Guests

    /// Adds a guest's songs at their fair place, or says why not (an error code for the phone).
    private func guestAdd(_ guest: String, _ songs: [JSONObject], _ policy: SharedQueuePolicy) -> String? {
        guard songs.count <= SharedQueuePolicy.maxPerRequest else { return "TOO_LARGE" }
        if let error = validate(items + songs) { return error }
        let upcomingStart = max(0, currentIndex + 1)
        var waitingIds = Set(items.dropFirst(upcomingStart).compactMap { $0["id"] as? String })
        if let current = currentItemId { waitingIds.insert(current) }
        var fresh: [JSONObject] = []
        var blocked = 0
        for song in songs {
            guard let id = song["id"] as? String, !waitingIds.contains(id), let converted = Self.song(from: song) else { continue }
            if ContentFilter.shared.isBlocked(converted) { blocked += 1; continue }
            waitingIds.insert(id)
            fresh.append(song)
        }
        if fresh.isEmpty { return blocked > 0 ? "NOT_ALLOWED" : nil } // already queued: nothing to do
        let waiting = items.dropFirst(upcomingStart).filter { policy.contributor(of: $0["id"] as? String ?? "") == guest }.count
        if let refusal = policy.refusal(guest: guest, count: fresh.count, waiting: waiting) { return refusal }
        remember(fresh)
        for song in fresh {
            // Credit each song before placing the next, so the guest's own order is kept.
            items.insert(song, at: fairIndex(for: guest, policy))
            policy.record(guest: guest, songIds: [song["id"] as? String ?? ""])
        }
        resetOriginal()
        if currentIndex < 0 {
            // Nothing was cued: cue the queue without starting it. Starting is the host's call.
            apply(index: 0, position: 0, playing: false, restart: true)
        } else {
            apply(index: currentIndex, position: 0, playing: player.isPlaying, restart: false)
        }
        return nil
    }

    /// Where a guest's next song goes: before the songs Autoplay lined up, and after the last
    /// song of the round this guest is on, so contributors take turns. The host's own queued
    /// songs count as one contributor; nobody's own order changes.
    private func fairIndex(for guest: String, _ policy: SharedQueuePolicy) -> Int {
        // Never in front of the host's Play Next songs or a song already fading in.
        let start = min(items.count, max(0, currentIndex + 1, player.firstFlexibleIndex))
        var end = start
        while end < items.count, !player.isAutoQueued(items[end]["id"] as? String ?? "") { end += 1 }
        var rounds: [String: Int] = [:]
        var lastAtOrBelow = start - 1
        let mine = (start ..< end).filter { policy.contributor(of: items[$0]["id"] as? String ?? "") == guest }.count
        for index in start ..< end {
            let who = policy.contributor(of: items[index]["id"] as? String ?? "") ?? "host"
            let round = rounds[who, default: 0]
            rounds[who] = round + 1
            if round <= mine { lastAtOrBelow = index }
        }
        return lastAtOrBelow + 1
    }

    private func fail(_ peerId: String) { sendError(peerId, "INVALID_MESSAGE") }

    // MARK: Queue helpers

    private var currentIndex: Int { player.currentIndex ?? -1 }
    private var currentItemId: String? { items.indices.contains(currentIndex) ? items[currentIndex]["id"] as? String : nil }

    private func indexOf(_ id: String?) -> Int { id.flatMap { id in items.firstIndex { ($0["id"] as? String) == id } } ?? -1 }

    private func move(_ from: Int, _ to: Int) {
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    private func resetOriginal() {
        original = items
        originalIndices = Array(items.indices)
        isShuffled = false
    }

    private func shuffleQueue() {
        guard items.count > 1 else { return }
        let currentId = currentItemId
        original = items
        var order = Array(items.indices)
        if currentIndex >= 0 { order.remove(at: currentIndex) }
        order.shuffle()
        if currentIndex >= 0 { order.insert(currentIndex, at: 0) }
        items = order.map { original[$0] }
        originalIndices = order
        isShuffled = true
        apply(index: indexOf(currentId), position: 0, playing: player.isPlaying, restart: false)
    }

    private func unshuffleQueue() {
        let currentId = currentItemId
        items = original
        resetOriginal()
        apply(index: indexOf(currentId), position: 0, playing: player.isPlaying, restart: false)
    }

    /// Why a list of songs from the phone can't be played here, or nil when it can.
    private func validate(_ songs: [JSONObject]) -> String? {
        guard songs.count <= Self.maxQueue else { return "TOO_LARGE" }
        for song in songs {
            guard let id = song["id"] as? String, !id.isEmpty else { return "INVALID_MESSAGE" }
            if (song["isLocal"] as? Bool) == true || id.hasPrefix("local_") { return "UNSHAREABLE_QUEUE" }
            // Only YouTube videos can be played here.
            guard ForeignBackup.isYouTubeVideoId(id) else { return "UNSHAREABLE_QUEUE" }
            if let duration = song["duration"] as? NSNumber, duration.int64Value < 0 { return "INVALID_MESSAGE" }
        }
        return nil
    }

    private func remember(_ songs: [JSONObject]) {
        for song in songs { if let id = song["id"] as? String { raw[id] = song } }
        if raw.count > 4_000 { raw = raw.filter { entry in items.contains { ($0["id"] as? String) == entry.key } } }
    }

    // MARK: Song conversion

    static func song(from item: JSONObject) -> Song? {
        guard let id = item["id"] as? String, ForeignBackup.isYouTubeVideoId(id) else { return nil }
        let artists = (item["artists"] as? [JSONObject] ?? []).compactMap { artist -> ArtistRef? in
            (artist["name"] as? String).map { ArtistRef(name: String($0.prefix(200)), id: artist["id"] as? String) }
        }
        let album = (item["album"] as? JSONObject).flatMap { a in (a["name"] as? String).map { AlbumRef(name: String($0.prefix(200)), id: a["id"] as? String) } }
        return Song(id: id, title: String(((item["title"] as? String) ?? id).prefix(300)), artists: artists, album: album,
                    duration: (item["duration"] as? NSNumber).map { $0.intValue }, thumbnail: item["thumbnail"] as? String,
                    explicit: (item["isExplicit"] as? Bool) ?? false)
    }

    /// The song as the phone's Kotlin model reads it; fields this app doesn't know are left out.
    func item(for song: Song) -> JSONObject {
        raw[song.id] ?? Self.item(for: song)
    }

    static func item(for song: Song) -> JSONObject {
        [
            "id": song.id, "title": song.title, "thumbnail": song.thumbnail as Any? ?? NSNull(),
            "artists": song.artists.map { ["id": $0.id as Any? ?? NSNull(), "name": $0.name] as JSONObject },
            "album": song.album.map { ["id": $0.id as Any? ?? NSNull(), "name": $0.name] as JSONObject } ?? NSNull(),
            "duration": song.duration as Any? ?? NSNull(), "isExplicit": song.explicit,
        ]
    }

    private static func repeatMode(_ name: String) -> RepeatMode {
        switch name { case "ALL": .all; case "ONE": .one; default: .off }
    }

    private static func repeatName(_ mode: RepeatMode) -> String {
        switch mode { case .all: "ALL"; case .one: "ONE"; case .off: "OFF" }
    }

    static func newId() -> String { DCCrypto.base64(DCCrypto.randomBytes(12)).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }

    // MARK: Player

    /// Puts the queue in `items` into the player.
    private func apply(index: Int, position: Double, playing: Bool, restart: Bool) {
        let songs = items.compactMap(Self.song(from:))
        guard songs.count == items.count else { return }
        player.applyRemoteQueue(songs, index: index, position: position, playing: playing, restart: restart)
    }

    private func adoptPlayerQueue() {
        items = player.queue.map(item(for:))
        resetOriginal()
    }

    /// Notices what happened on the Mac itself (a song ended, someone pressed a key) and
    /// updates what the phone is shown.
    private func syncFromPlayer() {
        let ids = player.queue.map(\.id)
        let known = items.map { $0["id"] as? String ?? "" }
        if ids != known {
            adoptPlayerQueue()
            title = nil
            revision += 1; queueRevision += 1; trackRevision += 1
            queueStateId = Self.newId()
            pendingState = true
        } else if currentItemId != lastItemId {
            trackRevision += 1; revision += 1
            pendingState = true
        }
        lastItemId = currentItemId
    }

    private var pendingState = false
    private var lastItemId: String?

    // MARK: Messages out

    private func playbackObject() -> JSONObject {
        var playback: JSONObject = [
            "queue": [
                "displayedItems": items, "originalItems": original, "currentIndex": min(currentIndex, items.count - 1), "isShuffled": isShuffled,
                "originalIndices": originalIndices, "recommendationsSongsOnly": false,
            ] as JSONObject,
            "repeatMode": Self.repeatName(player.repeatMode), "playing": player.isPlaying && currentIndex >= 0,
            "positionMs": Int64(max(0, player.currentTime) * 1000), "durationMs": Int64(max(0, player.duration) * 1000),
            "speed": 1.0, "ready": player.status == .ready, "finite": finite, "volume": min(1, max(0, player.volume)),
        ]
        if let title { playback["title"] = title }
        return playback
    }

    private func snapshot() -> JSONObject {
        ["sessionId": sessionId ?? "", "revision": revision, "queueRevision": queueRevision, "trackRevision": trackRevision,
         "playback": playbackObject(), "anchorTimeMs": 0, "queueStateId": queueStateId]
    }

    private func sendState(to peerId: String) {
        syncFromPlayer()
        _ = send(peerId, ["type": "STATE", "sessionId": sessionId as Any, "snapshot": snapshot()])
    }

    private func broadcastState() {
        for peer in controllers { _ = send(peer, ["type": "STATE", "sessionId": sessionId as Any, "snapshot": snapshot()]) }
        pendingState = false
    }

    private func broadcastUpdate(seek: Bool) {
        let playback = playbackObject()
        let message: JSONObject = [
            "type": "UPDATE", "sessionId": sessionId as Any, "revision": revision, "queueRevision": queueRevision, "trackRevision": trackRevision,
            "index": currentIndex, "positionMs": playback["positionMs"] as Any, "durationMs": playback["durationMs"] as Any,
            "playing": playback["playing"] as Any, "speed": 1.0, "repeatMode": playback["repeatMode"] as Any, "seek": seek,
            "ready": playback["ready"] as Any, "volume": playback["volume"] as Any, "queueStateId": queueStateId,
        ]
        for peer in controllers { _ = send(peer, message) }
    }

    private func sendError(_ peerId: String, _ error: String) {
        _ = send(peerId, ["type": "ERROR", "sessionId": sessionId as Any, "error": error])
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard sessionId != nil, !controllers.isEmpty else { return }
        syncFromPlayer()
        if pendingState { return broadcastState() }
        let playing = player.isPlaying
        // Volume or repeat changed on the Mac (or by another controller) shows on every phone,
        // also while paused.
        let settings = "\(player.volume)|\(Self.repeatName(player.repeatMode))"
        if playing || playing != lastPlaying || settings != lastSettings { broadcastUpdate(seek: false) }
        lastPlaying = playing
        lastSettings = settings
    }
}
