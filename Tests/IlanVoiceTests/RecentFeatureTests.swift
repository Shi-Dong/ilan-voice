import Foundation
@testable import IlanVoice

/// Guards for features merged after the first round of tests: the sidebar's
/// Update row (#67) and the iPhone page's solid top edge (#66).
@MainActor
func registerRecentFeatureTests() {
    let allStates: [Updater.State] = [
        .idle, .checking, .upToDate, .available(commit: "abc", summary: "New thing", date: nil),
        .installing("Building"), .readyToRestart, .failed("boom"),
    ]

    suite("Sidebar Update row") { test in
        test("every updater state has its own wording") {
            let titles = allStates.map(\.sidebarTitle)
            expectEqual(Set(titles).count, allStates.count)
            expectEqual(Updater.State.idle.sidebarTitle, "Check for updates")
            expectEqual(Updater.State.available(commit: "a", summary: "s", date: nil).sidebarTitle, "Install update")
            expectEqual(Updater.State.readyToRestart.sidebarTitle, "Restart to update")
            expect(Updater.State.failed("x").sidebarTitle.contains("try again"))
        }
        test("only an update to install or restart into is highlighted") {
            for state in allStates {
                let expected: Bool = switch state {
                case .available, .readyToRestart: true
                default: false
                }
                expectEqual(state.sidebarHighlighted, expected)
            }
        }
        test("icons are filled only when there is something to do") {
            expect(Updater.State.available(commit: "a", summary: "s", date: nil).sidebarIcon.hasSuffix(".fill"))
            expect(Updater.State.readyToRestart.sidebarIcon.hasSuffix(".fill"))
            for state in [Updater.State.idle, .checking, .upToDate, .failed("x")] {
                expect(!state.sidebarIcon.hasSuffix(".fill"), state.sidebarTitle)
            }
        }
    }

    suite("Sidebar links") { test in
        test("GitHub row opens the repository page") {
            expectEqual(Updater.repoURL.absoluteString, "https://github.com/Shi-Dong/ilan-voice")
            expectEqual(Updater.repoURL.host, "github.com")
        }
        test("data folder row opens the folder that holds agent.md") {
            expectEqual(Paths.agentFile.deletingLastPathComponent().standardizedFileURL.path,
                        Paths.root.standardizedFileURL.path)
            expectEqual(Paths.mcpFile.deletingLastPathComponent().standardizedFileURL.path,
                        Paths.root.standardizedFileURL.path)
        }
    }

    suite("iPhone page top edge") { test in
        let html = PhoneWebApp.html

        /// The value of a CSS custom property declared in the page, e.g. "--raised".
        func cssVariable(_ name: String) -> String? {
            guard let start = html.range(of: name + ":") else { return nil }
            let rest = html[start.upperBound...]
            return rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        }

        test("status bar colour matches the solid header") {
            let raised = cssVariable("--raised")
            expect(raised != nil, "no --raised colour in the page")
            let manifest = (try? JSONSerialization.jsonObject(with: Data(PhoneWebApp.manifest.utf8))) as? [String: Any]
            expectEqual(manifest?["theme_color"] as? String, raised)
            expect(html.contains(#"<meta name="theme-color" content="\#(raised ?? "")">"#),
                   "meta theme-color differs from the header colour")
        }
        test("header is solid and starts under the status bar") {
            expect(html.contains("background: var(--raised)") , "header lost its solid background")
            expect(html.contains("padding: calc(env(safe-area-inset-top)"), "header ignores the status bar inset")
        }
        test("page height follows the visible screen, with a fallback") {
            let vh = html.range(of: "height: 100vh;"), dvh = html.range(of: "height: 100dvh;")
            expect(vh != nil && dvh != nil, "100vh/100dvh missing")
            if let vh, let dvh { expect(vh.lowerBound < dvh.lowerBound, "100dvh must come after the 100vh fallback") }
        }
    }
}

/// "Up to date" stays honest: the app re-checks GitHub on its own.
@MainActor
func registerUpdateCheckTests() {
    suite("Automatic update checks") { test in
        let now = Date()
        test("checks when it never has, or the last check is old") {
            expect(Updater.needsCheck(state: .idle, lastChecked: nil, now: now, maxAge: 180))
            expect(Updater.needsCheck(state: .upToDate, lastChecked: now.addingTimeInterval(-600), now: now, maxAge: 180))
            expect(Updater.needsCheck(state: .failed("offline"), lastChecked: now.addingTimeInterval(-200), now: now, maxAge: 180))
        }
        test("does not re-check right after a check") {
            expect(!Updater.needsCheck(state: .upToDate, lastChecked: now.addingTimeInterval(-60), now: now, maxAge: 180))
        }
        test("never interrupts a check, an install or a known update") {
            let old = now.addingTimeInterval(-3_600)
            for state: Updater.State in [.checking, .installing("x"), .readyToRestart,
                                         .available(commit: "a", summary: "s", date: nil)] {
                expect(!Updater.needsCheck(state: state, lastChecked: old, now: now, maxAge: 180), state.sidebarTitle)
            }
        }
        test("background checks stay under GitHub's 60-an-hour limit") {
            expect(Updater.periodicCheckInterval <= 15 * 60)
            expect(3_600 / Updater.periodicCheckInterval + 3_600 / Updater.activationCheckAge < 60)
        }
    }
}
