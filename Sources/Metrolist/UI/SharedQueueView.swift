import SwiftUI

/// Window → Shared Queue: share this Mac's queue with guests, or join someone else's.
struct SharedQueueView: View {
    enum Side: String, CaseIterable { case host = "Share This Mac's Queue", join = "Join a Shared Queue" }
    @ViewState private var side = Side.host

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $side) {
                ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            switch side {
            case .host: SharedQueueHostView()
            case .join: SharedQueueJoinView()
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

/// Hosting: start and end, let someone join, the guests, and what they may do.
struct SharedQueueHostView: View {
    @Bindable private var guests = DeviceConnect.guests
    @Bindable private var policy = SharedQueue.shared.policy
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if !guests.enabled {
                Section {
                    Text("Let people on your Wi-Fi add songs to what this Mac is playing, from Metrolist on their phone or from this app on another Mac. This Mac keeps playing, so AutoMix still mixes their songs in.")
                    Text("Nothing listens for guests until you start, and it all stops when you end the shared queue or quit. Each new guest needs a six-digit code that you approve here.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Start Shared Queue") { SharedQueue.shared.start() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                runningSection
                joiningSection
                guestsSection
                Section {
                    Button("End Shared Queue", role: .destructive) { SharedQueue.shared.end() }
                    Text("Ends it for everyone. Guests you've let in are remembered and can rejoin without a code next time, until you remove them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let message = guests.message { Text(message).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
    }

    private var runningSection: some View {
        Section("Shared queue is on") {
            LabeledContent("Guests look for", value: guests.advertisedName)
            if let port = guests.port {
                LabeledContent("Or connect by address", value: SharedQueue.lanAddresses().map { "\($0):\(port)" }.joined(separator: ", "))
                    .textSelection(.enabled)
            } else {
                LabeledContent("Status", value: "Starting…")
            }
            Text("In Metrolist on Android, guests open the device picker and choose this Mac's “Shared queue” entry, or connect by address where the network hides devices.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Let guests control playback", isOn: $policy.guestsCanControl)
            Text(policy.guestsCanControl
                 ? "Guests can also play, pause, skip, change the volume and switch repeat. They still can't clear the queue, seek or reorder your songs."
                 : "Guests can only add songs, and remove songs they added. Their songs take turns with yours, before Autoplay's.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Let guests join while signed in to YouTube Music", isOn: $policy.allowSignedInGuests)
            Text(policy.allowSignedInGuests
                 ? "Metrolist only pairs devices that use the same account, so this Mac answers each guest with their own account's label. Their phone will say this Mac “uses the same account”; it doesn't, and no account details are exchanged. You still approve every new guest's code, and guests still only get guest rights."
                 : "Off: guests must sign out of YouTube Music in Metrolist before joining, because Metrolist only pairs devices on the same account.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var joiningSection: some View {
        Section("Let someone join") {
            if guests.isLocked {
                Text("Joining is locked for a while after repeated failures.").foregroundStyle(.red)
            } else if guests.pairingIsOpen, let until = guests.pairingOpenUntil {
                Text("Open until \(until.formatted(date: .omitted, time: .shortened)), for one new guest. When they connect, check that their screen shows the same six digits as yours.")
                Button("Stop Letting People Join") { guests.closePairing() }
            } else {
                Button("Let Someone Join (5 Minutes)") { guests.openPairing() }
                Text("New guests are refused unless joining is open. Guests you've let in before can reconnect at any time while the shared queue is on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var guestsSection: some View {
        Section("Guests") {
            if guests.paired.isEmpty { Text("None yet").foregroundStyle(.secondary) }
            ForEach(guests.paired) { guest in
                HStack {
                    Image(systemName: guests.connected.contains(guest.id) ? "person.fill.checkmark" : "person")
                    VStack(alignment: .leading) {
                        Text(guest.name)
                        let added = policy.added(by: guests.peerKey(guest.id))
                        Text((guests.connected.contains(guest.id) ? "Connected" : "Not connected") + (added > 0 ? " · \(added) song\(added == 1 ? "" : "s") in the queue" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { SharedQueue.shared.remove(guest: guest.id) }
                }
            }
            Text("Removing a guest disconnects them at once and deletes their key; they'd need a new code to come back.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Joining another Mac's shared queue as a guest.
struct SharedQueueJoinView: View {
    @Bindable private var client = SharedQueueClient.shared
    @ViewState private var address = ""
    @ViewState private var port = ""

    var body: some View {
        Form {
            switch client.phase {
            case .joined: joinedSections
            case .pairing(let code): pairingSection(code)
            case .connecting:
                Section { HStack { ProgressView().controlSize(.small); Text("Connecting to \(client.hostName)…") } }
            case .idle, .failed:
                if case .failed(let reason) = client.phase { Section { Text(reason).foregroundStyle(.orange) } }
                findSections
            }
        }
        .formStyle(.grouped)
        .onAppear { client.startBrowsing() }
        .onDisappear { client.stopBrowsing() }
    }

    @ViewBuilder private var findSections: some View {
        Section("On this network") {
            if client.found.isEmpty {
                Text(client.browsing ? "Looking for shared queues…" : "Not looking.").foregroundStyle(.secondary)
            }
            ForEach(client.found) { found in
                HStack {
                    Image(systemName: found.name.hasSuffix("Shared queue") ? "person.2.wave.2" : "desktopcomputer")
                    Text(found.name)
                    Spacer()
                    Button("Join") { client.join(found) }
                }
            }
        }
        Section("By address") {
            TextField("Address", text: $address, prompt: Text("192.168.1.20"))
            TextField("Port", text: $port, prompt: Text("50485"))
            Button("Join") { client.join(address: address, port: UInt16(port) ?? 0) }
                .disabled(address.isEmpty || UInt16(port) == nil)
            Text("Some networks (eduroam, many offices) hide devices from each other. Ask the host for the address shown in their Shared Queue window.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if client.rememberedHosts > 0 {
            Section {
                Button("Forget Shared Queues I've Joined", role: .destructive) { client.forgetHosts() }
            }
        }
    }

    private func pairingSection(_ code: String) -> some View {
        Section("Check the code") {
            Text(code).font(.system(size: 44, weight: .bold, design: .monospaced)).kerning(6).frame(maxWidth: .infinity)
            Text("The host's Mac shows six digits too. Continue only if they're exactly these; the host has to approve on their side as well.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { client.refuse() }
                Spacer()
                Button("The Digits Match") { client.approve() }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var joinedSections: some View {
        Section("Joined \(client.hostName)") {
            if let song = client.nowPlaying {
                HStack {
                    ArtworkView(url: song.thumbnail, size: 44, cornerRadius: 6)
                    VStack(alignment: .leading) {
                        Text(song.title)
                        Text(song.artistText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: client.playing ? "speaker.wave.2" : "pause")
                }
            } else {
                Text("Nothing is playing.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Previous", systemImage: "backward.fill") { client.control("PREVIOUS") }
                Button(client.playing ? "Pause" : "Play", systemImage: client.playing ? "pause.fill" : "play.fill") { client.control(client.playing ? "PAUSE" : "PLAY") }
                Button("Next", systemImage: "forward.fill") { client.control("NEXT") }
                Spacer()
                Button("Leave") { client.leave() }
            }
            .labelStyle(.iconOnly)
            Text("Add songs from any song's menu with “Add to Shared Queue”. The host decides whether guests can play, pause and skip.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = client.message { Text(message).foregroundStyle(.orange) }
        }
        Section("Up next on \(client.hostName)") {
            let upcoming = Array(client.queue.enumerated()).filter { $0.offset > client.currentIndex }
            if upcoming.isEmpty { Text("Nothing queued.").foregroundStyle(.secondary) }
            ForEach(upcoming.prefix(50), id: \.offset) { index, song in
                HStack {
                    Text(song.title).lineLimit(1)
                    Text(song.artistText).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .contextMenu { Button("Remove (if you added it)") { client.remove(at: index) } }
            }
        }
    }
}

/// "Add to Shared Queue" for song and item menus, shown while this Mac has joined one.
struct AddToSharedQueueButton: View {
    let songs: () async -> [Song]
    @Bindable private var client = SharedQueueClient.shared

    var body: some View {
        if client.joined {
            Button("Add to Shared Queue", systemImage: "person.2.wave.2") {
                Task { client.add(await songs()) }
            }
        }
    }
}
