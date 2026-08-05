import SwiftUI

@main
struct BrainSurfacerApp: App {
    var body: some Scene {
        Window("BrainSurfacer", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 920, height: 620)
    }
}
