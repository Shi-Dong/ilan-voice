import Foundation

MainActor.assumeIsolated {
    registerShellToolTests()
    registerFileToolsTests()
    registerCoreLogicTests()
    exit(runAll() == 0 ? 0 : 1)
}
