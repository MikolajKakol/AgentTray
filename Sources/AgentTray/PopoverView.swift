import AgentTrayCore
import AppKit
import SwiftUI

struct PopoverView: View {
    let store: SessionStore
    @State private var expanded: Set<String> = []
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let listing = store.listing
        VStack(spacing: 0) {
            if listing.rows.isEmpty {
                VStack(spacing: 4) {
                    Text("Brak aktywnych sesji")
                        .font(.headline)
                    Text("Śledzone katalogi: \(store.trackedDirectories.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                FittedScrollView(maxHeight: 560) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections(listing.rows), id: \.group) { section in
                            Text(Self.title(of: section.group))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(section.rows) { row in
                                SessionRowView(
                                    row: row,
                                    now: store.now,
                                    isExpanded: expanded.contains(row.id),
                                    toggle: { toggle(row.id) },
                                    acknowledge: { store.acknowledge(row) },
                                    restore: { store.unacknowledge(row) }
                                )
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Ustawienia…") {
                    NSApplication.shared.activate()
                    openSettings()
                }
                if listing.rows.contains(where: \.canAcknowledge) {
                    Button("Przejrzyj wszystkie") {
                        store.acknowledgeAll()
                    }
                    .help("Oznacz wszystkie czekające sesje jako przejrzane; wrócą, gdy coś się w nich zmieni")
                }
                Spacer()
                Button("Zakończ") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 400)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private struct RowSection {
        var group: SessionGroup
        var rows: [SessionRow]
    }

    /// Rows are already in display order; split them where the group changes.
    private func sections(_ rows: [SessionRow]) -> [RowSection] {
        var result: [RowSection] = []
        for row in rows {
            if result.last?.group == row.group {
                result[result.count - 1].rows.append(row)
            } else {
                result.append(RowSection(group: row.group, rows: [row]))
            }
        }
        return result
    }

    private static func title(of group: SessionGroup) -> String {
        switch group {
        case .waitingForYou: "Czeka na Ciebie"
        case .uncertain: "Może czekać na zgodę"
        case .working: "Pracuje"
        case .acknowledged: "Przejrzane"
        case .dimmed: "Nieaktywne"
        }
    }
}

/// A scroll view as tall as its content, up to `maxHeight`.
/// A plain `ScrollView` with only a maximum height can collapse to almost nothing
/// inside a `MenuBarExtra` window, hiding the whole list.
struct FittedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
    }
}

struct SessionRowView: View {
    let row: SessionRow
    let now: Date
    let isExpanded: Bool
    let toggle: () -> Void
    let acknowledge: () -> Void
    let restore: () -> Void

    private var snapshot: SessionSnapshot { row.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    header
                    Text(StatusText.statusLine(for: row.status, lastActivity: snapshot.lastActivity, now: now))
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                    if !isExpanded {
                        if let prompt = snapshot.lastPrompt {
                            Text(prompt)
                                .font(.callout)
                                .lineLimit(2)
                        }
                        if let message = messageLine {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)

                acknowledgeButton
            }

            if isExpanded {
                expandedText
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(row.isDimmed || row.isAcknowledged ? 0.55 : 1)
    }

    @ViewBuilder
    private var acknowledgeButton: some View {
        if row.canAcknowledge {
            Button(action: acknowledge) {
                Image(systemName: "checkmark.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help("Oznacz jako przejrzane: sesja zniknie z licznika do czasu, aż coś się w niej zmieni")
        } else if row.isAcknowledged {
            Button(action: restore) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help("Przywróć do licznika")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(snapshot.title)
                .font(.headline)
                .lineLimit(1)
            Text([snapshot.sourceLabel, snapshot.workingDirectoryName].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// While a tool call is open the row shows "Nazwa: summary" instead of the last message.
    private var messageLine: String? {
        StatusText.toolLine(for: row.status) ?? snapshot.lastMessage
    }

    private var expandedText: some View {
        FittedScrollView(maxHeight: 240) {
            VStack(alignment: .leading, spacing: 8) {
                if let prompt = snapshot.lastPrompt {
                    Text(prompt)
                        .font(.callout)
                }
                if let tool = StatusText.toolLine(for: row.status) {
                    Text(tool)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let message = snapshot.lastMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusColor: Color {
        switch row.group {
        case .waitingForYou: .orange
        case .uncertain: .yellow
        case .working, .acknowledged, .dimmed: .secondary
        }
    }
}
