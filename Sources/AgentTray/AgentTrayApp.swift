import AgentTrayCore
import SwiftUI

@main
struct AgentTrayApp: App {
    @State private var settings: AppSettings
    @State private var store: SessionStore

    init() {
        let settings = AppSettings()
        let store = SessionStore(settings: settings)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, store: store)
        }
    }
}

struct MenuBarLabel: View {
    let store: SessionStore

    var body: some View {
        let listing = store.listing
        let symbol = MenuBarIcon.symbol(waitingCount: listing.waitingCount, hasUncertain: listing.hasUncertain)
        if listing.waitingCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                Text("\(listing.waitingCount)")
            }
        } else {
            Image(systemName: symbol)
        }
    }
}

enum MenuBarIcon {
    static func symbol(waitingCount: Int, hasUncertain: Bool) -> String {
        if hasUncertain { return "questionmark.circle" }
        return waitingCount > 0 ? "circle.grid.2x2.fill" : "circle.grid.2x2"
    }
}
