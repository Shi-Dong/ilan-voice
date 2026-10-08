import AppKit
import SwiftUI

/// The small "Updating Ilan Voice" window: a progress bar while the new
/// version downloads and builds, then Restart Now / Later. The app never
/// restarts on its own.
@MainActor
final class UpdateWindow {
    static let shared = UpdateWindow()
    private var window: NSWindow?

    func show(_ updater: Updater) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 170),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Software Update"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: UpdateProgressView(updater: updater) { [weak self] in
                self?.window?.close()
            })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateProgressView: View {
    @ObservedObject var updater: Updater
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(size: 52)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold))
                switch updater.state {
                case .installing(let step):
                    ProgressView(value: updater.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.mint)
                    Text(step).font(.caption).foregroundStyle(.secondary)
                    // Shown greyed out until the build finishes.
                    buttons {
                        Button("Restart Now") {}
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                    }
                case .readyToRestart:
                    ProgressView(value: 1).progressViewStyle(.linear).tint(Theme.mint)
                    Text("The new version is installed. Restart Ilan Voice to start using it. If you choose Later, it is used the next time the app opens.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    buttons {
                        Button("Later", action: close)
                        Button("Restart Now") { updater.restartNow() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(Theme.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    buttons {
                        Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Updater.logFile]) }
                        Button("Close", action: close).keyboardShortcut(.defaultAction)
                    }
                default:
                    ProgressView().progressViewStyle(.linear)
                    buttons { Button("Close", action: close) }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .preferredColorScheme(.dark)
        .tint(Theme.mint)
    }

    private var title: String {
        switch updater.state {
        case .readyToRestart: "Update ready"
        case .failed: "Update failed"
        default: "Updating Ilan Voice…"
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}
