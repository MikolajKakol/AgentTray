import AgentTrayCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: SessionStore
    @State private var newPattern = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                ForEach(Array(settings.patterns.enumerated()), id: \.offset) { index, pattern in
                    PatternRow(pattern: pattern, matchCount: store.matchCounts[pattern]) { edited in
                        updatePattern(at: index, to: edited)
                    } onDelete: {
                        settings.patterns.remove(at: index)
                        store.reconfigure()
                    }
                    .id("\(index)-\(pattern)")
                }
                HStack {
                    TextField("Nowy wzorzec", text: $newPattern, prompt: Text("~/Speedwave/*/home/.claude"))
                        .onSubmit(addPattern)
                    Button("Dodaj", action: addPattern)
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Katalogi .claude")
            } footer: {
                Text("`~` to katalog domowy, `*` pasuje do jednego segmentu ścieżki, `**` do dowolnej liczby (do 6).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Progi") {
                Stepper(value: dimAfter, in: 1...max(1, settings.hideAfterHours - 1)) {
                    Text("Przyciemniaj po: \(settings.dimAfterHours) h")
                }
                Stepper(value: hideAfter, in: (settings.dimAfterHours + 1)...max(1000, settings.hideAfterHours)) {
                    Text("Ukrywaj po: \(settings.hideAfterHours) h")
                }
                Stepper(value: $settings.uncertainAfterSeconds, in: 1...600) {
                    Text("Próg niepewnego stanu: \(settings.uncertainAfterSeconds) s")
                }
                Stepper(value: $settings.countWaitingAfterSeconds, in: 0...600) {
                    Text("Licz czekające po: \(settings.countWaitingAfterSeconds) s")
                }
                .help("Sesja trafia do licznika w pasku menu dopiero po tylu sekundach czekania")
            }

            Section {
                Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 420)
    }

    /// Hide threshold must stay above the dim threshold; changing one never crosses the other.
    private var dimAfter: Binding<Int> {
        Binding(
            get: { settings.dimAfterHours },
            set: { settings.dimAfterHours = min($0, settings.hideAfterHours - 1); store.reconfigure() }
        )
    }

    private var hideAfter: Binding<Int> {
        Binding(
            get: { settings.hideAfterHours },
            set: { settings.hideAfterHours = max($0, settings.dimAfterHours + 1); store.reconfigure() }
        )
    }

    private func addPattern() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        settings.patterns.append(pattern)
        newPattern = ""
        store.reconfigure()
    }

    private func updatePattern(at index: Int, to pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard settings.patterns.indices.contains(index), !trimmed.isEmpty, trimmed != settings.patterns[index] else { return }
        settings.patterns[index] = trimmed
        store.reconfigure()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Nie udało się zmienić ustawienia: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// One editable pattern. Edits apply on Enter so half-typed patterns are never expanded.
private struct PatternRow: View {
    let pattern: String
    let matchCount: Int?
    let onCommit: (String) -> Void
    let onDelete: () -> Void
    @State private var draft: String

    init(pattern: String, matchCount: Int?, onCommit: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.pattern = pattern
        self.matchCount = matchCount
        self.onCommit = onCommit
        self.onDelete = onDelete
        _draft = State(initialValue: pattern)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Wzorzec", text: $draft)
                    .labelsHidden()
                    .onSubmit { onCommit(draft) }
                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(matchCount == 0 ? .red : .secondary)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Usuń wzorzec")
        }
    }

    private var matchLabel: String {
        guard let matchCount else { return "…" }
        if matchCount == 0 { return "brak dopasowań" }
        if matchCount == 1 { return "1 katalog" }
        let fewForm = (2...4).contains(matchCount % 10) && !(12...14).contains(matchCount % 100)
        return "\(matchCount) \(fewForm ? "katalogi" : "katalogów")"
    }
}
