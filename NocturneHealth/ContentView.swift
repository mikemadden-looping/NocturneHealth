import SwiftUI

struct ContentView: View {
    @State private var urlText = Prefs.baseURL?.absoluteString ?? ""
    @State private var tokenText = Keychain.read() ?? ""
    @State private var backfillDays = Prefs.backfillDays
    @State private var healthRequested = Prefs.healthRequested
    @State private var connection: ConnectionState = .idle
    @State private var healthError: String?
    @State private var syncing = false
    @State private var status = SyncStatus.current()
    @State private var confirmReset = false

    private enum ConnectionState: Equatable {
        case idle, testing, ok
        case failed(String)
    }

    private var configured: Bool { Prefs.baseURL != nil && !(Keychain.read() ?? "").isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                nocturneSection
                healthSection
                syncSection
            }
            .navigationTitle("Nocturne Health")
            .onReceive(NotificationCenter.default.publisher(for: .syncStatusChanged)) { _ in
                status = SyncStatus.current()
            }
            .confirmationDialog("Send everything again?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Re-send last \(backfillDays) days") {
                    Prefs.resetSyncProgress()
                    status = SyncStatus.current()
                    syncNow()
                }
            } message: {
                Text("Nocturne updates records it already has, so this won't create duplicates.")
            }
        }
    }

    // MARK: Sections

    private var nocturneSection: some View {
        Section {
            TextField("https://your-name.nocturne.run", text: $urlText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("API token (noc_…)", text: $tokenText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                saveAndTest()
            } label: {
                HStack {
                    Text("Save & test connection")
                    Spacer()
                    switch connection {
                    case .idle: EmptyView()
                    case .testing: ProgressView()
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            .disabled(connection == .testing)
            if case .failed(let message) = connection {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Nocturne")
        } footer: {
            Text("Make a token in Nocturne under Settings → Connectors & Apps → API Tokens with write access to step count, heart rate and treatments. It's kept in this iPhone's Keychain and only sent to your Nocturne site.")
        }
    }

    private var healthSection: some View {
        Section {
            Button {
                Task { await requestHealth() }
            } label: {
                HStack {
                    Text(healthRequested ? "Review Apple Health access" : "Allow Apple Health access")
                    Spacer()
                    if healthRequested {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            if let healthError {
                Text(healthError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Reads steps, heart rate and workouts. If nothing arrives in Nocturne, check Settings → Health → Data Access & Devices → NocturneHealth and turn the categories on.")
        }
    }

    private var syncSection: some View {
        Section {
            Picker("First sync goes back", selection: $backfillDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }
            .onChange(of: backfillDays) { _, days in Prefs.backfillDays = days }
            .disabled(status.syncedThrough != nil)

            Button {
                syncNow()
            } label: {
                HStack {
                    Text("Sync now")
                    Spacer()
                    if syncing { ProgressView() }
                }
            }
            .disabled(syncing || !configured || !healthRequested)

            LabeledContent("Last sync", value: status.lastSyncText)
            if let through = status.syncedThrough {
                LabeledContent("Steps & heart rate through",
                               value: through.formatted(date: .abbreviated, time: .shortened))
            }
            if let summary = status.summary {
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = status.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Button("Send everything again…", role: .destructive) { confirmReset = true }
                .disabled(syncing || status.syncedThrough == nil)
        } header: {
            Text("Sync")
        } footer: {
            Text("Syncs when you open the app and in the background when Health gets new data (iOS allows steps about once an hour). Steps and heart rate are sent in 5-minute buckets. Health data can't be read while the iPhone is locked, so some syncs wait for the next unlock.")
        }
    }

    // MARK: Actions

    private func saveAndTest() {
        guard let url = NocturneAPI.normalizedURL(urlText) else {
            connection = .failed("Enter an https address, like https://your-name.nocturne.run")
            return
        }
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            connection = .failed("Enter your Nocturne API token.")
            return
        }
        urlText = url.absoluteString
        tokenText = token
        Prefs.baseURL = url
        Keychain.save(token)
        connection = .testing
        Task {
            do {
                try await NocturneAPI(baseURL: url, token: token).test()
                connection = .ok
                syncNow()
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func requestHealth() async {
        do {
            try await HealthReader.shared.requestAuthorization()
            Prefs.healthRequested = true
            healthRequested = true
            healthError = nil
            AppDelegate.startObserving()
            syncNow()
        } catch {
            healthError = error.localizedDescription
        }
    }

    private func syncNow() {
        guard configured, Prefs.healthRequested else { return }
        syncing = true
        Task {
            await SyncEngine.shared.sync()
            status = SyncStatus.current()
            syncing = false
        }
    }
}

/// A snapshot of sync progress for display.
struct SyncStatus {
    var lastSync: Date?
    var syncedThrough: Date?
    var summary: String?
    var error: String?

    static func current() -> SyncStatus {
        SyncStatus(lastSync: Prefs.lastSyncAt, syncedThrough: Prefs.syncedThrough,
                   summary: Prefs.lastSummary, error: Prefs.lastError)
    }

    var lastSyncText: String {
        guard let lastSync else { return "Never" }
        return lastSync.formatted(.relative(presentation: .named))
    }
}
