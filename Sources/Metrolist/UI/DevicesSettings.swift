import SwiftUI

struct DevicesSettings: View {
    @Bindable private var connect = DeviceConnect.shared
    @ViewState private var confirmingForgetAll = false

    var body: some View {
        Form {
            mainSection
            sharedQueueSection
            if connect.enabled {
                pairingSection
                pairedSection
                activitySection
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget every paired phone?", isPresented: $confirmingForgetAll) {
            Button("Forget All", role: .destructive) { connect.forgetAll() }
        }
    }

    private var mainSection: some View {
        Section("Device Connect") {
            Toggle("Let a paired Android phone control this Mac", isOn: $connect.enabled)
            Text("Off by default. While it is on, this Mac announces itself on your Wi-Fi and a paired phone can play, pause, skip, change volume and edit the queue; AutoMix and the equalizer keep working. Nothing else about this Mac, your library, history, settings or account is shared.")
                .font(.callout).foregroundStyle(.secondary)
            if connect.enabled {
                LabeledContent("Status", value: connect.listening ? "Listening on the local network, port \(connect.port.map(String.init) ?? "?")" : "Starting…")
                TextField("Name shown on the phone", text: $connect.deviceName)
                Toggle("Match my YouTube Music account", isOn: $connect.useAccount)
                if connect.useAccount {
                    HStack {
                        Text(connect.accountIdKnown ? "Account id read" : "Account id not read yet").foregroundStyle(.secondary)
                        Spacer()
                        Button("Read From YouTube Music") { Task { await connect.lookUpAccountId() } }
                    }
                }
                Text(connect.useAccount
                     ? "The phone must be signed in to the same YouTube Music account."
                     : "The phone must be signed out of YouTube Music in Metrolist, or pairing is refused. Turn this on if the phone is signed in.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message = connect.message { Text(message).foregroundStyle(.orange) }
        }
    }

    private var sharedQueueSection: some View {
        Section("Shared queue") {
            Text("To let other people add songs (their phones get add-only access, not control), use Window > Shared Queue (⇧⌘J). It's separate from this and is off until you start it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        Section("Pair a new phone") {
            if connect.isLocked {
                Text("Pairing is locked for a while after repeated failures.").foregroundStyle(.red)
            } else if connect.pairingIsOpen, let until = connect.pairingOpenUntil {
                Text("Pairing is open until \(until.formatted(date: .omitted, time: .shortened)). On the phone, open Metrolist's device picker and choose this Mac, then check that the same six digits appear on both.")
                Button("Close Pairing") { connect.closePairing() }
            } else {
                Button("Open Pairing for 5 Minutes") { connect.openPairing() }
                Text("A phone that isn't paired yet is refused unless pairing is open. Anything on this Wi-Fi can see that this Mac is there, so keep pairing closed except when you are pairing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var pairedSection: some View {
        Section("Paired phones") {
            if connect.paired.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(connect.paired) { device in
                HStack {
                    Image(systemName: "iphone")
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(connect.connected.contains(device.id) ? "Connected" : "Not connected").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget", role: .destructive) { connect.forget(device.id) }
                }
            }
            if !connect.paired.isEmpty { Button("Forget All", role: .destructive) { confirmingForgetAll = true } }
            Text("Forgetting a phone deletes its key from the Keychain and disconnects it immediately.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var activitySection: some View {
        Section("Recent activity") {
            ForEach(Array(connect.events.suffix(8).enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()) }
        }
    }
}

/// Shown when a phone asks to pair: compare the code with the phone's, then approve.
/// For a shared queue the same check applies, but the request is to join as a guest.
struct PairingRequestSheet: View {
    let request: DCPairingRequest
    var endpoint: DeviceConnect = .shared

    private var isGuest: Bool { endpoint.mode == .guest }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isGuest ? "person.2.wave.2" : "iphone.and.arrow.forward").font(.largeTitle)
            Text(isGuest ? "Someone wants to join your shared queue" : "A phone wants to control this Mac").font(.headline)
            Text(request.sas).font(.system(size: 48, weight: .bold, design: .monospaced)).kerning(6)
            Text(isGuest
                 ? "Let them join only if their device shows exactly these six digits. Guests can add songs to your queue\(SharedQueue.shared.policy.guestsCanControl ? " and control playback" : ""); they can't see anything else on this Mac."
                 : "Approve only if the phone shows exactly these six digits, and you started this pairing yourself. If you didn't, or the digits differ, press Refuse.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Refuse", role: .cancel) { endpoint.reject(request) }
                Button(isGuest ? "The Digits Match: Let Them Join" : "The Digits Match: Pair") { endpoint.approve(request) }.buttonStyle(.borderedProminent)
            }
            Text("This request expires at \(request.expires.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}

/// Presents pairing requests (your own phones and shared-queue guests) wherever the app is,
/// since they can arrive at any moment.
struct PairingRequestPresenter: ViewModifier {
    @Bindable private var connect = DeviceConnect.shared
    @Bindable private var guests = DeviceConnect.guests

    private var pending: (request: DCPairingRequest, endpoint: DeviceConnect)? {
        if let request = connect.requests.first { return (request, connect) }
        if let request = guests.requests.first { return (request, guests) }
        return nil
    }

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { pending?.request }, set: { _ in })) { request in
            PairingRequestSheet(request: request, endpoint: guests.requests.contains(request) ? guests : connect)
        }
    }
}
