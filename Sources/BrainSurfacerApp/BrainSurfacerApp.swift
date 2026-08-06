import AppIntents
import BrainSurfacerApple
import SwiftUI

@main
struct BrainSurfacerApp: App {
    init() {
        BrainSurfacerAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        Window("BrainSurfacer", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 920, height: 620)
    }
}

struct BrainSurfacerAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetCurrentBrainSurfacerContextIntent(),
            phrases: [
                "What is open in \(.applicationName)",
                "What's open in \(.applicationName)",
                "What files are open in \(.applicationName)",
                "Which files are open in \(.applicationName)",
                "Get my current \(.applicationName) context",
                "What am I working on in \(.applicationName)",
                "Show my current \(.applicationName) context"
            ],
            shortTitle: "Current Context",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: ReadBrainSurfacerNoteIntent(),
            phrases: [
                "Read \(\.$note) in \(.applicationName)",
                "Get \(\.$note) from \(.applicationName)"
            ],
            shortTitle: "Read Note",
            systemImageName: "doc.text"
        )
    }
}
