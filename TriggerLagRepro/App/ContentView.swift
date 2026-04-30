import Foundation
import RiveRuntime
import SwiftUI
import UIKit

private let testTriggerProperty = TriggerProperty(path: "trigger")
private let logPrefix = "[TriggerLagRepro/Log]"

@MainActor
final class LogStore: ObservableObject {
    @Published var entries: [String] = []

    func append(_ line: String) {
        print("\(logPrefix) \(line)")
        entries.append(line)
        if entries.count > 100 {
            entries.removeFirst(entries.count - 100)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var copiedText: String {
        entries.joined(separator: "\n")
    }
}

private final class TriggerLagRiveViewDelegate: NSObject, RiveUIViewDelegate {
    func view(_ view: RiveUIView, didReceiveError error: RiveUIViewError) {
        print("[TriggerLagRepro/RiveView] error description=\(error.localizedDescription)")
    }
}

private let triggerLagRiveViewDelegate = TriggerLagRiveViewDelegate()

private struct TouchProbeView: UIViewRepresentable {
    var onTouch: (CGPoint) -> Void

    func makeUIView(context: Context) -> TouchProbeUIView {
        let view = TouchProbeUIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ uiView: TouchProbeUIView, context: Context) {
        uiView.onTouch = onTouch
    }
}

private final class TouchProbeUIView: UIView {
    var onTouch: ((CGPoint) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if bounds.contains(point) {
            onTouch?(point)
        }

        return nil
    }
}

struct ContentView: View {
    @State private var rive: Rive?
    @State private var viewModelInstance: ViewModelInstance?
    @State private var isLoading = false
    @State private var frameRate = 120
    @State private var swiftFireT1: Double?
    @State private var pendingEditorTouchT1s: [Double] = []
    @State private var editorTouchSequence = 0
    @State private var lastEditorTouchT1: Double?
    @StateObject private var logStore = LogStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Frame Rate", selection: $frameRate) {
                Text("60 Hz").tag(60)
                Text("120 Hz").tag(120)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("FrameRatePicker")

            ZStack {
                RiveUIViewRepresentable(rive: rive, delegate: triggerLagRiveViewDelegate)
                    .frameRate(.fps(frameRate))
                    .id(frameRate)

                TouchProbeView { location in
                    noteEditorTouch(at: location)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("RiveView")

            Button {
                fireFromSwift()
            } label: {
                Text("Fire from Swift")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModelInstance == nil)
            .accessibilityIdentifier("SwiftFireButton")

            logList

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = logStore.copiedText
                    logStore.append("copied log lines=\(logStore.entries.count)")
                } label: {
                    Text("Copy Log")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(logStore.entries.isEmpty)
                .accessibilityIdentifier("CopyLogButton")

                Button {
                    swiftFireT1 = nil
                    pendingEditorTouchT1s.removeAll()
                    logStore.clear()
                } label: {
                    Text("Clear Log")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ClearLogButton")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await loadRiveIfNeeded()
        }
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(logStore.entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("LogList")
    }

    @MainActor
    private func fireFromSwift() {
        guard let viewModelInstance else {
            logStore.append("swift-fire skipped: view model not loaded")
            return
        }

        let t1 = Date().timeIntervalSinceReferenceDate
        swiftFireT1 = t1
        logStore.append("swift-fire T1=\(formatTimestamp(t1)) frameRate=\(frameRate)")
        viewModelInstance.fire(trigger: testTriggerProperty)
    }

    @MainActor
    private func noteEditorTouch(at location: CGPoint) {
        let t1 = Date().timeIntervalSinceReferenceDate
        if let lastEditorTouchT1, t1 - lastEditorTouchT1 < 0.08 {
            return
        }

        lastEditorTouchT1 = t1
        editorTouchSequence += 1
        pendingEditorTouchT1s.append(t1)
        let x = String(format: "%.1f", location.x)
        let y = String(format: "%.1f", location.y)
        logStore.append(
            "editor-touch #\(editorTouchSequence) T1=\(formatTimestamp(t1)) frameRate=\(frameRate) x=\(x) y=\(y) pending=\(pendingEditorTouchT1s.count)"
        )
        let touchSeq = editorTouchSequence
        let touchT1 = t1

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let now = Date().timeIntervalSinceReferenceDate
                self.logStore.append(
                    "sentinel-mainq #\(touchSeq) T=\(self.formatTimestamp(now)) delta=\(self.formatDelta(now - touchT1)) s"
                )
            }
        }

        Task { @MainActor in
            let now = Date().timeIntervalSinceReferenceDate
            self.logStore.append(
                "sentinel-mainactor #\(touchSeq) T=\(self.formatTimestamp(now)) delta=\(self.formatDelta(now - touchT1)) s"
            )
        }
    }

    @MainActor
    private func loadRiveIfNeeded() async {
        guard rive == nil, isLoading == false else { return }
        isLoading = true

        do {
            let worker = try await Worker()
            let file = try await File(source: .local("basics", .main), worker: worker)
            let artboard = try await file.createArtboard("Main")
            let viewModelInstance = try await file.createViewModelInstance(
                .viewModelDefault(from: .name("MainVM"))
            )

            let loadedRive = try await Rive(
                file: file,
                artboard: artboard,
                dataBind: .instance(viewModelInstance),
                fit: .layout(scaleFactor: .automatic)
            )

            self.viewModelInstance = viewModelInstance
            rive = loadedRive
            logStore.append("rive load succeeded file=basics artboard=Main vm=MainVM trigger=trigger")

            Task { @MainActor in
                do {
                    for try await _ in viewModelInstance.stream(of: testTriggerProperty) {
                        let t2 = Date().timeIntervalSinceReferenceDate
                        var line = "body-entered T2=\(formatTimestamp(t2)) frameRate=\(frameRate)"
                        if let t1 = swiftFireT1 {
                            let delta = t2 - t1
                            line += " | swift-path delta=\(formatDelta(delta)) s"
                            swiftFireT1 = nil
                        } else if let oldestT1 = pendingEditorTouchT1s.first,
                                  let newestT1 = pendingEditorTouchT1s.last {
                            let pendingCount = pendingEditorTouchT1s.count
                            line += " | editor-path pending-touches=\(pendingCount)"
                            line += " oldest-delta=\(formatDelta(t2 - oldestT1)) s"
                            line += " newest-delta=\(formatDelta(t2 - newestT1)) s"
                            pendingEditorTouchT1s.removeAll()
                        } else {
                            line += " | editor-side path (no T1)"
                        }
                        logStore.append(line)
                    }
                } catch {
                    logStore.append("stream failed: \(String(describing: error))")
                }
            }
        } catch {
            logStore.append("rive load failed: \(String(describing: error))")
        }

        isLoading = false
    }

    private func formatTimestamp(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func formatDelta(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
