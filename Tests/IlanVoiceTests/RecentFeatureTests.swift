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
