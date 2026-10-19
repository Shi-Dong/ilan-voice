import Foundation
@testable import IlanVoice

/// The floating pill appears on the display you are working on.
@MainActor
func registerPillScreenTests() {
    // Two displays side by side, as AppKit sees them: the main one on the left
    // (1920 x 1080), a second one to its right (2560 x 1440), bottoms aligned.
    let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    let screens = [left, right]
    suite("Pill goes on the display you are working on") { test in
        test("an app focused on one display, the pointer left on the other: the pill follows the focused window") {
            let window = CGRect(x: 2200, y: 300, width: 1200, height: 800)  // on the right
            expectEqual(FloatingHUD.screenIndex(focusedWindow: window, mouse: CGPoint(x: 500, y: 500), screens: screens), 1)
            let back = CGRect(x: 100, y: 100, width: 900, height: 700)  // and the other way round
            expectEqual(FloatingHUD.screenIndex(focusedWindow: back, mouse: CGPoint(x: 3000, y: 500), screens: screens), 0)
        }
        test("a window across both displays: the one showing more of it") {
            let across = CGRect(x: 1500, y: 200, width: 1000, height: 600)  // 420 px on the left, 580 on the right
            expectEqual(FloatingHUD.screenIndex(focusedWindow: across, mouse: CGPoint(x: 100, y: 100), screens: screens), 1)
        }
        test("no focused window (the desktop), or one off every screen: the pointer's display, else the main one") {
            expectEqual(FloatingHUD.screenIndex(focusedWindow: nil, mouse: CGPoint(x: 3000, y: 900), screens: screens), 1)
            let offscreen = CGRect(x: -5000, y: -5000, width: 800, height: 600)
            expectEqual(FloatingHUD.screenIndex(focusedWindow: offscreen, mouse: CGPoint(x: 10, y: 10), screens: screens), 0)
            expect(FloatingHUD.screenIndex(focusedWindow: nil, mouse: CGPoint(x: -100, y: -100), screens: screens) == nil)
        }
        test("window list frames (top-left origin, y down) become AppKit frames (bottom-left, y up)") {
            // A 800 x 600 window 100 pt below the top of a 1080-pt-tall main display.
            let frame = FloatingHUD.appKitFrame(CGRect(x: 2000, y: 100, width: 800, height: 600), primaryHeight: 1080)
            expectEqual(frame, CGRect(x: 2000, y: 380, width: 800, height: 600))
        }
    }
}
