import Foundation
@testable import IlanVoice

/// Double-tapping the talk key brings the window forward.
@MainActor
func registerDoubleTapTests() {
    func run(_ events: [(Bool, Double)]) -> [Bool] {
        var d = DoubleTapDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        return events.map { d.record(down: $0.0, at: t0.addingTimeInterval($0.1)) }
    }
    suite("Double tap") { test in
        test("two quick taps fire once, on the second release") {
            expectEqual(run([(true, 0), (false, 0.08), (true, 0.25), (false, 0.33)]), [false, false, false, true])
        }
        test("a single tap does not fire") {
            expectEqual(run([(true, 0), (false, 0.1)]), [false, false])
        }
        test("taps too far apart do not fire") {
            expect(!run([(true, 0), (false, 0.1), (true, 0.9), (false, 1.0)]).contains(true))
        }
        test("a hold (real recording) is not a tap") {
            expect(!run([(true, 0), (false, 1.5), (true, 1.6), (false, 1.7)]).contains(true))
            expect(!run([(true, 0), (false, 0.1), (true, 0.2), (false, 1.4)]).contains(true))
        }
        test("a third quick tap starts a new pair") {
            let r = run([(true, 0), (false, 0.05), (true, 0.15), (false, 0.2), (true, 0.3), (false, 0.35)])
            expectEqual(r.filter { $0 }.count, 1)
        }
    }
}
