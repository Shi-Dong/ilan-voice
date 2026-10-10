import Foundation
@testable import IlanVoice

/// File tools run against a fresh temporary folder. Only paths that never
/// create a backup are exercised (backups go to the real data folder).
func registerFileToolsTests() {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ilan-voice-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    suite("FileTools") { test in
        test("resolve expands ~ and relative paths") {
            let dir = try tempDir()
            expectEqual(FileTools.resolve("~", relativeTo: "/").path,
                        URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path)
            expectEqual(FileTools.resolve("a/../b.txt", relativeTo: dir.path).path, dir.appendingPathComponent("b.txt").path)
            expectEqual(FileTools.resolve("new/deep/file.txt", relativeTo: dir.path).path,
                        dir.appendingPathComponent("new/deep/file.txt").path)
        }
        test("isInside respects folder boundaries") {
            let url = URL(fileURLWithPath: "/Users/a/project/file.txt")
            expect(FileTools.isInside(url, "/Users/a/project"))
            expect(FileTools.isInside(url, "/Users/a/project/"))
            expect(!FileTools.isInside(url, "/Users/a/proj"))
        }
        test("credentials are protected") {
            let ssh = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/id_ed25519")
            expect(FileTools.isProtected(FileTools.resolve(ssh.path, relativeTo: "/")))
            expect(FileTools.read(path: ssh.path, offset: nil, limit: nil, base: "/").contains("holds credentials"))
            expect(FileTools.write(path: "~/.aws/credentials", content: "x", base: "/", blocked: []).hasPrefix("Not changed"))
        }
        test("block list has one entry per line") {
            expectEqual(FileTools.blockedPaths("/System\n\n  /Library  \n").count, 2)
            expect(FileTools.defaultBlockList.split(separator: "\n").contains("/System"))
        }
        test("write creates new files and honours the block list") {
            let dir = try tempDir()
            let target = dir.appendingPathComponent("sub/notes.txt")
            expect(FileTools.write(path: target.path, content: "one\ntwo", base: "/", blocked: []).hasPrefix("Created"))
            expectEqual(try String(contentsOf: target, encoding: .utf8), "one\ntwo")
            let other = dir.appendingPathComponent("x.txt")
            expect(FileTools.write(path: other.path, content: "x", base: "/", blocked: [dir.path]).contains("block list"))
            expect(!FileManager.default.fileExists(atPath: other.path))
        }
        test("edit refuses blocked files before touching them") {
            let dir = try tempDir()
            let file = dir.appendingPathComponent("keep.txt")
            try "hello".write(to: file, atomically: true, encoding: .utf8)
            let result = FileTools.edit(path: file.path, oldText: "hello", newText: "bye", replaceAll: false,
                                        base: "/", blocked: [dir.path])
            expect(result.contains("block list"), result)
            expectEqual(try String(contentsOf: file, encoding: .utf8), "hello")
        }
        test("read numbers lines and pages") {
            let dir = try tempDir()
            let file = dir.appendingPathComponent("lines.txt")
            try "a\nb\nc\nd".write(to: file, atomically: true, encoding: .utf8)
            let page = FileTools.read(path: file.path, offset: 2, limit: 2, base: "/")
            expect(page.contains("     2\tb") && page.contains("     3\tc"), page)
            expect(!page.contains("\td\n"), page)
            expect(page.contains("lines 2–3 of 4"), page)
            expect(FileTools.read(path: dir.path, offset: nil, limit: nil, base: "/").contains("is a folder"))
            expect(FileTools.read(path: dir.appendingPathComponent("nope").path, offset: nil, limit: nil, base: "/")
                .hasPrefix("Error: no such file"))
        }
        test("diff shows removed and added lines") {
            expectEqual(FileTools.diff(old: "a\nb", new: "c"), "- a\n- b\n+ c")
        }
    }
}
