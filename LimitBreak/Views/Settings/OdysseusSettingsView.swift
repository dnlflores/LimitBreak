import SwiftUI

/// Connection settings for a self-hosted Odysseus server.
///
/// The flow is deliberately linear, because each step depends on the one above
/// it: paste a URL and token, test them, then pick from the endpoints that
/// token is actually allowed to use. Nothing is guessed — the model list comes
/// from the server, so a lifter can't select a model their token can't reach.
struct OdysseusSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var urlDraft = OdysseusConfig.baseURL
    @State private var tokenDraft = ""
    @State private var showTokenField = !KeychainStore.hasOdysseusToken

    @State private var connection: ConnectionState = .untested
    @State private var endpoints: [OdysseusClient.Endpoint] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?

    @State private var selectedEndpointID = OdysseusConfig.endpointID
    @State private var selectedModel = OdysseusConfig.model

    private enum ConnectionState: Equatable {
        case untested
        case testing
        case connected(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    serverSection
                    if canReachServer { modelSection }
                    if OdysseusConfig.isConfigured { sessionSection }
                    disconnectSection
                }
                .padding()
            }
            .obsidianBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("My Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .task {
            // A previously configured server is worth re-listing on open, so a
            // model that has since been removed doesn't sit here looking valid.
            if canReachServer { await loadModels() }
        }
    }

    /// Enough to talk to the server, whether or not a model has been picked.
    private var canReachServer: Bool {
        !OdysseusConfig.baseURL.isEmpty && KeychainStore.hasOdysseusToken
    }

    // MARK: - Server

    private var serverSection: some View {
        section("SERVER") {
            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("BASE URL")
                TextField("https://your-machine.ts.net", text: $urlDraft)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.caption.monospaced())
                    .padding(12)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    fieldLabel("API TOKEN")
                    Spacer()
                    statusBadge
                }

                if let stored = KeychainStore.odysseusToken, !showTokenField {
                    HStack {
                        Text(stored.maskedAPIKey)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textDim)
                        Spacer()
                        Button("Replace") {
                            tokenDraft = ""
                            showTokenField = true
                            Haptics.shared.tick()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.emerald)
                    }
                } else {
                    SecureField("ody_...", text: $tokenDraft)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .padding(12)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                }

                testButton

                switch connection {
                case .connected(let message):
                    statusLine(message, color: Theme.emerald, icon: "checkmark.circle.fill")
                case .failed(let message):
                    statusLine(message, color: Theme.crimson, icon: "exclamationmark.triangle.fill")
                case .untested, .testing:
                    EmptyView()
                }

                Text("Your server is only reachable while this iPhone is on the same "
                     + "tailnet. Nothing here leaves your devices.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
            .cardStyle()
        }
    }

    private var testButton: some View {
        Button {
            Task { await testConnection() }
        } label: {
            HStack(spacing: 8) {
                if connection == .testing {
                    ProgressView().tint(.white)
                    Text("TESTING\u{2026}")
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("TEST CONNECTION")
                }
            }
            .font(.subheadline.weight(.bold))
            .kerning(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .glassCTA(tint: Theme.teal.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connection == .testing || !hasCredentialsToTest)
    }

    /// A token is needed, but not necessarily typed — a stored one counts.
    private var hasCredentialsToTest: Bool {
        !urlDraft.trimmingCharacters(in: .whitespaces).isEmpty
            && (!tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty || KeychainStore.hasOdysseusToken)
    }

    // MARK: - Model selection

    private var modelSection: some View {
        section("MODEL") {
            VStack(alignment: .leading, spacing: 12) {
                if isLoadingModels {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.teal)
                        Text("Loading endpoints\u{2026}")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                } else if let modelsError {
                    statusLine(modelsError, color: Theme.crimson, icon: "exclamationmark.triangle.fill")
                    Button("Retry") { Task { await loadModels() } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.emerald)
                } else if endpoints.isEmpty {
                    Text("This token has no model endpoints available.")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                } else {
                    ForEach(endpoints) { endpoint in
                        endpointBlock(endpoint)
                    }
                }
            }
            .cardStyle()
        }
    }

    private func endpointBlock(_ endpoint: OdysseusClient.Endpoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(endpoint.displayName.uppercased())
                .font(.caption2.weight(.bold))
                .kerning(1)
                .foregroundStyle(Theme.textDim)

            ForEach(endpoint.models, id: \.self) { model in
                let isSelected = selectedEndpointID == endpoint.endpointId && selectedModel == model
                Button {
                    select(endpoint: endpoint, model: model)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.subheadline)
                            .foregroundStyle(isSelected ? Theme.emerald : Theme.textDim)
                        Text(model)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                    }
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(
                        isSelected ? Theme.emerald.opacity(0.12) : Theme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Session

    private var sessionSection: some View {
        section("CONVERSATION") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(OdysseusConfig.sessionID == nil ? "No session yet" : "Session active")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if OdysseusConfig.sessionID != nil {
                        Button("Start fresh") {
                            OdysseusConfig.clearSession()
                            Haptics.shared.tick()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.emerald)
                    }
                }
                Text("Your server remembers previous plans in one long-running session, "
                     + "so the coach builds on what it already programmed for you. Starting "
                     + "fresh clears that history.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
            .cardStyle()
        }
    }

    private var disconnectSection: some View {
        Button(role: .destructive) {
            OdysseusConfig.reset()
            urlDraft = ""
            tokenDraft = ""
            showTokenField = true
            endpoints = []
            selectedEndpointID = nil
            selectedModel = nil
            connection = .untested
            Haptics.shared.tick()
        } label: {
            Text("DISCONNECT SERVER")
                .font(.subheadline.weight(.bold))
                .kerning(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.crimson)
                .background(Theme.crimson.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Saves what's been typed, then pings. Saving first is what lets the rest
    /// of the screen (and the coach) use these values immediately.
    private func testConnection() async {
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedToken = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if !typedToken.isEmpty, !KeychainStore.setOdysseusToken(typedToken) {
            connection = .failed("Couldn't save the token to the Keychain.")
            return
        }
        guard let token = KeychainStore.odysseusToken else {
            connection = .failed("No API token saved.")
            return
        }
        OdysseusConfig.baseURL = url

        connection = .testing
        do {
            let ping = try await OdysseusClient.ping(baseURL: url, token: token)
            guard ping.ok else {
                connection = .failed("The server reported it isn't healthy.")
                Haptics.shared.tick()
                return
            }
            connection = .connected(ping.summary)
            tokenDraft = ""
            showTokenField = false
            Haptics.shared.success()
            await loadModels()
        } catch {
            // Keep the token saved so a tailnet blip doesn't force a re-paste;
            // the badge is what tells them it isn't working.
            connection = .failed(message(for: error))
            Haptics.shared.tick()
        }
    }

    private func loadModels() async {
        guard let token = KeychainStore.odysseusToken else { return }
        let url = OdysseusConfig.baseURL
        guard !url.isEmpty else { return }

        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }

        do {
            endpoints = try await OdysseusClient.models(baseURL: url, token: token)
            // If exactly one model is on offer, picking it saves a tap and gets
            // the lifter to a usable state in one screen.
            if selectedModel == nil,
               let only = endpoints.first,
               endpoints.count == 1,
               only.models.count == 1,
               let model = only.models.first {
                select(endpoint: only, model: model)
            }
        } catch {
            modelsError = message(for: error)
        }
    }

    private func select(endpoint: OdysseusClient.Endpoint, model: String) {
        OdysseusConfig.select(
            endpointID: endpoint.endpointId,
            endpointName: endpoint.name,
            model: model
        )
        selectedEndpointID = endpoint.endpointId
        selectedModel = model
        Haptics.shared.tick()
    }

    private func message(for error: Error) -> String {
        (error as? OdysseusClient.OdysseusError)?.errorDescription
            ?? error.localizedDescription
    }

    // MARK: - Building blocks

    @ViewBuilder
    private var statusBadge: some View {
        switch connection {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.emerald)
        case .failed:
            Label("Not working", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.crimson)
        case .untested, .testing:
            EmptyView()
        }
    }

    private func statusLine(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .kerning(1)
            .foregroundStyle(Theme.textDim)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .kerning(1)
                .foregroundStyle(Theme.textDim)
            content()
        }
    }
}
