import AppKit
import Foundation
@testable import IlanVoice

MainActor.assumeIsolated {
    // scripts/test.sh points the home folder at a fresh temporary one, so the
    // tests never touch the real ~/Library/Application Support/Ilan Voice.
    let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? ""
    let homePath = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
    let rootPath = Paths.root.standardizedFileURL.resolvingSymlinksInPath().path
    guard !home.isEmpty, rootPath.hasPrefix(homePath + "/") else {
        print("Refusing to run: Paths.root (\(Paths.root.path)) is not inside a throwaway home. Use scripts/test.sh.")
        exit(2)
    }
    _ = NSApplication.shared  // some app code reads NSApp

    registerShellToolTests()
    registerFileToolsTests()
    registerCoreLogicTests()
    registerPhoneTests()
    registerRecentFeatureTests()
    let failed = runAll()
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
    exit(failed == 0 ? 0 : 1)
}
