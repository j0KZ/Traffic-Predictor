import SwiftUI
import AppKit

@main
struct TrafficLensApp: App {
    @State private var model = AppModel(
        routePath: ProcessInfo.processInfo.environment["TRAFFICLENS_ROUTE"] ?? "route.json",
        dbPath: ProcessInfo.processInfo.environment["TRAFFICLENS_DB"] ?? "trafficlens.sqlite"
    )

    init() {
        // Lanzada con `swift run` no es un .app: sin esto la ventana no toma
        // foco ni aparece en el Dock.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("TrafficLens") {
            MainView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { model.start() }
                .onDisappear { model.stop() }
                // Instrumento de medición: los valores cambian, no se animan.
                .transaction { $0.animation = nil }
        }
    }
}
