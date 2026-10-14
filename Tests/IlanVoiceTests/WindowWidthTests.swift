import Foundation
@testable import IlanVoice

/// The main window's minimum width leaves room for the sidebar and the whole
/// chat header, so nothing is squeezed or cut off at the edges.
@MainActor
func registerWindowWidthTests() {
    suite("Main window minimum width") { test in
        test("a header that fits keeps the usual minimum") {
            expectEqual(MainView.minimumWidth(sidebar: 240, header: 400), MainView.minimumWidth)
        }
        test("a wider header (an update button, a long title) widens it: sidebar + divider + header") {
            expectEqual(MainView.minimumWidth(sidebar: 240, header: 615), 856)
            expectEqual(MainView.minimumWidth(sidebar: 320, header: 615), 936)  // a wider sidebar counts too
        }
        test("a hidden sidebar takes no room; fractions round up") {
            expectEqual(MainView.minimumWidth(sidebar: 0, header: 800.2), 802)
        }
    }
}
