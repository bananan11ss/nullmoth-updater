import Foundation

struct ShellResult {
    let status: Int32
    let output: String
}

enum Shell {
    /// Runs a program without a shell and returns its combined stdout+stderr.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 120, stderr: Bool = true) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        // The NVIDIA driver prints debug lines on stderr in every Metal process, which breaks JSON output.
        p.standardError = stderr ? pipe : FileHandle.nullDevice
        do { try p.run() } catch { return ShellResult(status: -1, output: error.localizedDescription) }
        // Read before waiting: a full pipe would otherwise block the child forever.
        var data = Data()
        let reader = DispatchQueue(label: "shell.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        _ = done.wait(timeout: .now() + 2)
        return ShellResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Single-quotes a string for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a /bin/sh command line as root through the standard macOS administrator prompt.
    /// Blocks until the command finishes, so call it off the main thread.
    static func runAsAdmin(_ command: String) -> ShellResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ShellResult(status: -1, output: "не удалось создать AppleScript")
        }
        let out = script.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? -1
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "ошибка"
            // -128 is "User canceled" in the password dialog.
            return ShellResult(status: Int32(code), output: code == -128 ? "Отменено пользователем" : msg)
        }
        return ShellResult(status: 0, output: out.stringValue ?? "")
    }
}
