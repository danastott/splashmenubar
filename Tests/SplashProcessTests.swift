import XCTest
@testable import SplashMenuBar

final class SplashProcessTests: XCTestCase {
    /// A fake splash install: `bin/splash` answers `--version`, and a real
    /// long-running executable sits deep inside the install, where splash's
    /// server process runs from (a Cellar's bundled python, a venv, …).
    private var prefix: String!
    private var serverExecutable: String!
    private var serverProc: Process?

    override func setUpWithError() throws {
        prefix = NSTemporaryDirectory()
            + "splashmenubar-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: (prefix as NSString).appendingPathComponent("bin"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: (prefix as NSString).appendingPathComponent("libexec/python/bin"),
            withIntermediateDirectories: true)
        let script = "#!/bin/sh\necho \"Splash 9.9.9\"\n"
        try script.write(
            toFile: (prefix as NSString).appendingPathComponent("bin/splash"),
            atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: (prefix as NSString).appendingPathComponent("bin/splash"))
        // A real executable, so a launched process's recorded path lives
        // inside the fake install (the server's python, in splash's case).
        serverExecutable = (prefix as NSString)
            .appendingPathComponent("libexec/python/bin/python3")
        try FileManager.default.copyItem(
            atPath: "/bin/sleep", toPath: serverExecutable)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: serverExecutable)
        p.arguments = ["300"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        serverProc = p
    }

    override func tearDownWithError() throws {
        serverProc?.terminate()
        serverProc = nil
        try? FileManager.default.removeItem(atPath: prefix)
    }

    private var serverPID: pid_t {
        pid_t(serverProc!.processIdentifier)
    }

    func testServerVersionFromPrefix() {
        XCTAssertEqual(SplashProcess.serverVersion(pid: serverPID), "9.9.9")
    }

    func testServerVersionAfterBinaryRemoved() throws {
        // A brew upgrade removes the old install's files; the process keeps
        // running and ps still knows its launch command.
        try? FileManager.default.removeItem(atPath: serverExecutable)
        // Some test hosts (sandboxed runners) can't read the launch command
        // of a process whose binary is unlinked; the production app context
        // can (verified against a real upgraded splash server).
        guard SplashProcess.executablePath(of: serverPID) != nil else {
            throw XCTSkip("this test host can't read the launch command of a process whose binary was removed")
        }
        XCTAssertEqual(SplashProcess.serverVersion(pid: serverPID), "9.9.9")
    }

    func testServerVersionFallsBackToPathSplash() throws {
        // No install around the process: the PATH's splash answers.
        guard let splash = SplashInstaller.locate("splash") else {
            throw XCTSkip("splash isn't installed on this machine")
        }
        let path = SplashProcess.versionString(
            SplashProcess.runCapture(splash, ["--version"]))
        XCTAssertNotNil(path)
        // A pid nobody's: nothing to read from the process, the fallback is
        // the only answer.
        XCTAssertEqual(SplashProcess.serverVersion(pid: 99999999), path)
    }

    func testExecutablePathOfLiveProcess() {
        // The kernel reports the /private/var form of /var paths.
        guard let recorded = SplashProcess.executablePath(of: serverPID) else {
            return XCTFail("no executable path")
        }
        let canonical = recorded.replacingOccurrences(of: "/private/var/", with: "/var/")
        XCTAssertEqual(canonical, serverExecutable)
    }

    func testCellarVersion() {
        XCTAssertEqual(
            SplashProcess.cellarVersion(
                in: "/opt/homebrew/Cellar/splash/1.5.0/libexec/python/bin/python3"),
            "1.5.0")
        XCTAssertEqual(
            SplashProcess.cellarVersion(in: "/opt/homebrew/Cellar/splash/1.6.0/bin/splash"),
            "1.6.0")
        // Another formula's Cellar is not splash's version.
        XCTAssertNil(SplashProcess.cellarVersion(
            in: "/opt/homebrew/Cellar/python@3.13/3.13.2/bin/python3"))
        XCTAssertNil(SplashProcess.cellarVersion(in: "/usr/local/bin/splash"))
        // No version segment.
        XCTAssertNil(SplashProcess.cellarVersion(in: "/opt/homebrew/Cellar/splash"))
    }

    func testPrefixWithSplashBinary() {
        let deep = (prefix as NSString).appendingPathComponent("libexec/python/bin/python3")
        XCTAssertEqual(SplashProcess.prefixWithSplashBinary(deep), prefix)
        // Nothing on this walk-up owns a bin/splash.
        XCTAssertNil(SplashProcess.prefixWithSplashBinary("/usr/bin/nonexistent-tool"))
    }

    func testVersionString() {
        XCTAssertEqual(SplashProcess.versionString("Splash 1.6.0"), "1.6.0")
        XCTAssertEqual(SplashProcess.versionString("Splash 1.6.0\n"), "1.6.0")
        XCTAssertEqual(SplashProcess.versionString("splash\t2.0.1"), "2.0.1")
        XCTAssertNil(SplashProcess.versionString(""))
        XCTAssertNil(SplashProcess.versionString(nil))
        // Not a version: no digit at all.
        XCTAssertNil(SplashProcess.versionString("error: not found"))
    }
}
