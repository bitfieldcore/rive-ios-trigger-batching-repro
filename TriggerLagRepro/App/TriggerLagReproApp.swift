import RiveRuntime
import SwiftUI

@main
struct TriggerLagReproApp: App {
    init() {
        RenderContextManager.shared().defaultRenderer = RendererType.riveRenderer
        RiveLog.logger = RiveLog.system(levels: .default)
        print("[TriggerLagRepro/App] init renderer=riveRenderer")
        print("[TriggerLagRepro/App] rive logging enabled levels=default")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
