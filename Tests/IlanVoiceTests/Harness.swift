import Foundation

// A tiny test harness. The Command Line Tools ship neither XCTest nor the
// macro plugin Swift Testing needs, so `scripts/test.sh` compiles the app as a
// library and links these files into a plain executable instead.

struct TestCase {
    let suite: String
    let name: String
    let body: () throws -> Void
}

nonisolated(unsafe) var registered: [TestCase] = []
nonisolated(unsafe) var currentFailures: [String] = []

/// Registers the tests declared inside `body` under one suite name.
func suite(_ name: String, _ body: (_ test: (String, @escaping () throws -> Void) -> Void) -> Void) {
    body { testName, run in registered.append(TestCase(suite: name, name: testName, body: run)) }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    guard !condition else { return }
    let note = message()
    currentFailures.append("\(file):\(line)\(note.isEmpty ? "" : " — \(note)")")
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) {
    expect(a == b, "\(a) != \(b)", file: file, line: line)
}

/// Runs every registered test; returns the number of failed tests.
func runAll() -> Int {
    var failed = 0
    let start = Date()
    for test in registered {
        currentFailures = []
        do { try test.body() } catch { currentFailures.append("threw \(error)") }
        if currentFailures.isEmpty { continue }
        failed += 1
        print("✘ \(test.suite) › \(test.name)")
        for failure in currentFailures { print("    \(failure)") }
    }
    let seconds = String(format: "%.2f", Date().timeIntervalSince(start))
    print(failed == 0
          ? "✔ \(registered.count) tests passed in \(seconds)s"
          : "✘ \(failed) of \(registered.count) tests failed (\(seconds)s)")
    return failed
}
