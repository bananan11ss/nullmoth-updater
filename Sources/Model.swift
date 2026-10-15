import AppKit
import Foundation

@MainActor
final class UpdaterModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case downloading(Double, String)
        case done(String)
        case failed(String)
    }

    @Published var info = SystemInfo()
    @Published var releases: [Release] = []
    @Published var selected: String = ""          // release version picked in the list
    @Published var phase: Phase = .idle
    @Published var log = ""
    @Published var needsReboot = false
    @Published var loadingInfo = false

    private var downloader: Downloader?
    private var logTimer: Timer?

    var busy: Bool {
        switch phase { case .working, .downloading: return true; default: return false }
    }

    var selectedRelease: Release? { releases.first { $0.version == selected } ?? releases.first }
    var latest: Release? { releases.first }

    var updateAvailable: Bool {
        guard let l = latest else { return false }
        guard let have = info.installedVersion else { return true }
        return Version.newer(l.version, than: have)
    }

    // MARK: - Status

    func refresh() {
        loadingInfo = true
        loadTuning()
        Task.detached {
            let s = SystemInfo.collect()
            await MainActor.run { self.info = s; self.loadingInfo = false }
        }
        Task { await checkReleases() }
    }

    func checkReleases() async {
        do {
            let r = try await ReleaseService.fetchReleases()
            releases = r
            if selected.isEmpty || !r.contains(where: { $0.version == selected }) { selected = r.first?.version ?? "" }
        } catch {
            phase = .failed("Не удалось проверить обновления: \(error.localizedDescription)")
        }
    }

    /// /Library/NullMoth is root-only, so reading the installed version needs the admin prompt.
    func readVersionAsAdmin() {
        phase = .working("Читаю установленную версию…")
        Task.detached {
            let r = Shell.runAsAdmin("cat /Library/NullMoth/driver-version 2>/dev/null || true")
            let v = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                if r.status != 0 { self.phase = .failed(r.output); return }
                if v.isEmpty { self.phase = .done("Файл версии не найден: драйвер ставился без записи версии"); return }
                try? v.write(to: Paths.cachedVersion, atomically: true, encoding: .utf8)
                self.info.installedVersion = v
                self.phase = .done("Установлена версия \(v)")
            }
        }
    }

    // MARK: - Package

    private func packageDir(_ r: Release) -> URL {
        Paths.support.appendingPathComponent("packages/\(r.version)", isDirectory: true)
    }

    /// Downloads (or reuses) the package, verifies SHA-256, unpacks it and returns pkgroot.
    private func preparePackage(_ r: Release) async throws -> URL {
        let dir = packageDir(r)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tar = dir.appendingPathComponent(r.packageName)

        var haveGood = false
        if FileManager.default.fileExists(atPath: tar.path) {
            phase = .working("Проверяю уже скачанный пакет…")
            haveGood = await Task.detached { ReleaseService.sha256(of: tar) }.value == r.sha256
        }
        if !haveGood {
            try await download(r, to: tar)
            phase = .working("Проверяю SHA-256…")
            let got = await Task.detached { ReleaseService.sha256(of: tar) }.value
            guard got == r.sha256 else {
                try? FileManager.default.removeItem(at: tar)
                throw ReleaseError.format("Скачанный файл не совпал с SHA256SUMS — удалён. Попробуй ещё раз.")
            }
        }

        phase = .working("Распаковываю…")
        let x = dir.appendingPathComponent("x", isDirectory: true)
        try? FileManager.default.removeItem(at: x)
        try FileManager.default.createDirectory(at: x, withIntermediateDirectories: true)
        let t = await Task.detached { Shell.run("/usr/bin/tar", ["-xzf", tar.path, "-C", x.path], timeout: 600) }.value
        guard t.status == 0 else { throw ReleaseError.format("tar: \(t.output)") }

        let root = x.appendingPathComponent("pkgroot")
        let candidates = [root, x]
        guard let pkg = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("install.sh").path) }) else {
            throw ReleaseError.format("В пакете нет install.sh")
        }
        phase = .working("Проверяю файлы пакета (SHA256SUMS)…")
        let c = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            p.arguments = ["-a", "256", "-c", "SHA256SUMS", "--quiet"]
            p.currentDirectoryURL = pkg
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try? p.run(); p.waitUntilExit()
            return ShellResult(status: p.terminationStatus, output: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }.value
        guard c.status == 0 else { throw ReleaseError.format("Файлы пакета не совпали с SHA256SUMS:\n\(c.output.prefix(800))") }
        return pkg
    }

    private func download(_ r: Release, to dest: URL) async throws {
        let sizeText = ByteCountFormatter.string(fromByteCount: r.packageSize, countStyle: .file)
        phase = .downloading(0, "Скачиваю \(r.packageName) (\(sizeText))…")
        let sources = [r.packageURL, URL(string: ReleaseService.mirror + r.sha256)!]
        var lastError: Error?
        for src in sources {
            let d = Downloader(destination: dest) { [weak self] done, total in
                Task { @MainActor in
                    guard let self else { return }
                    let t = total > 0 ? total : max(r.packageSize, 1)
                    let f = Double(done) / Double(t)
                    self.phase = .downloading(f, "Скачиваю с \(src.host ?? "")… \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) из \(sizeText)")
                }
            }
            downloader = d
            do { _ = try await d.download(src); downloader = nil; return }
            catch { lastError = error; appendLog("Источник \(src.host ?? "") не ответил: \(error.localizedDescription)\n") }
        }
        downloader = nil
        throw lastError ?? ReleaseError.network("загрузка не удалась")
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        phase = .failed("Загрузка отменена")
    }

    // MARK: - Install / remove

    func install(dryRun: Bool) {
        guard let r = selectedRelease else { return }
        log = ""
        Task {
            do {
                let pkg = try await preparePackage(r)
                let title = dryRun ? "Проверка без изменений (CHECK=1)" : "Установка \(r.version)"
                let env = dryRun ? "CHECK=1 " : ""
                let ok = await runRootScript(title: title, in: pkg, command: "\(env)/bin/bash ./install.sh")
                if ok {
                    if dryRun {
                        phase = .done("Проверка пройдена: эта система может принять драйвер \(r.version). Ничего не изменено.")
                    } else {
                        try? r.version.write(to: Paths.cachedVersion, atomically: true, encoding: .utf8)
                        info.installedVersion = r.version
                        needsReboot = true
                        phase = .done("Драйвер \(r.version) установлен. Нужна перезагрузка.")
                    }
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func uninstall() {
        guard let r = selectedRelease ?? latest else { return }
        log = ""
        Task {
            do {
                let pkg = try await preparePackage(r)
                let ok = await runRootScript(title: "Удаление драйвера", in: pkg, command: "/bin/bash ./uninstall.sh")
                if ok {
                    try? FileManager.default.removeItem(at: Paths.cachedVersion)
                    info.installedVersion = nil
                    needsReboot = true
                    phase = .done("Драйвер удалён. Перезагрузись.")
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The driver keeps translated shaders across updates. After an update that changes the translator,
    /// a stale entry can make a game render wrong; clearing makes every app rebuild them on first use.
    func clearShaderCache() {
        log = ""
        let cmd = "for d in /Library/GPUBundles/nvmtl/aircache /Library/GPUBundles/nvmtl/spvcache; do " +
            "[ -d \"$d\" ] && [ ! -L \"$d\" ] && /usr/bin/find \"$d\" -mindepth 1 -delete; done; echo cleared"
        phase = .working("Очищаю кэш шейдеров…")
        Task.detached {
            let r = Shell.runAsAdmin(cmd)
            await MainActor.run {
                self.phase = r.status == 0 ? .done("Кэш шейдеров очищен. Первый запуск игр будет дольше, пока шейдеры собираются заново.")
                                          : .failed(r.output)
            }
        }
    }

    func reboot() {
        let r = Shell.runAsAdmin("/sbin/shutdown -r now")
        if r.status != 0 { phase = .failed(r.output) }
    }

    /// Runs a command as root in `dir`, streaming its output into the log view.
    private func runRootScript(title: String, in dir: URL, command: String) async -> Bool {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logFile = Paths.logs.appendingPathComponent("\(stamp).log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        phase = .working("\(title)… (займёт несколько минут: kmutil пересобирает kernel collection)")
        startTailing(logFile)
        let uid = getuid()
        let line = "cd \(Shell.quote(dir.path)) && \(command) >> \(Shell.quote(logFile.path)) 2>&1; " +
            "rc=$?; /usr/sbin/chown \(uid) \(Shell.quote(logFile.path)); exit $rc"
        let r = await Task.detached { Shell.runAsAdmin(line) }.value
        stopTailing()
        reloadLog(logFile)
        if r.status != 0 {
            phase = .failed("\(title): ошибка (код \(r.status)). \(r.status == -128 ? "" : "Смотри лог ниже. Скрипт сам откатывает изменения при ошибке.")")
            if r.status == -128 { phase = .failed("Отменено") }
            return false
        }
        return true
    }

    private func startTailing(_ file: URL) {
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadLog(file) }
        }
    }

    private func stopTailing() { logTimer?.invalidate(); logTimer = nil }

    private func reloadLog(_ file: URL) {
        if let s = try? String(contentsOf: file, encoding: .utf8), !s.isEmpty { log = s }
    }

    private func appendLog(_ s: String) { log += s }

    func openLogs() { NSWorkspace.shared.open(Paths.logs) }

    // MARK: - Per-app tuning

    @Published var tuneProcess = "java"
    @Published var tuneOn: Set<String> = []
    @Published var pluginPerApp = false

    func loadTuning() {
        pluginPerApp = Tuning.pluginSupportsPerApp()
        tuneOn = Tuning.enabled(in: Tuning.readConf(), process: tuneProcess)
    }

    func applyTuning() {
        let proc = tuneProcess.trimmingCharacters(in: .whitespaces)
        guard Tuning.validProcessName(proc) else { phase = .failed("Имя программы: только буквы, цифры, точка, дефис и пробел"); return }
        let text = Tuning.readConf()
        guard !text.isEmpty else { phase = .failed("Не найден \(Tuning.conf): драйвер не установлен?"); return }
        let new = Tuning.render(text, process: proc, on: tuneOn)
        let tmp = Paths.support.appendingPathComponent("nvrm610.conf.new")
        do { try new.write(to: tmp, atomically: true, encoding: .utf8) } catch { phase = .failed(error.localizedDescription); return }
        // cp onto the existing file keeps its owner and mode; the first backup is the conf as the installer left it
        let c = Shell.quote(Tuning.conf)
        let cmd = "[ -f \(c).before-updater ] || /bin/cp -p \(c) \(c).before-updater; /bin/cp \(Shell.quote(tmp.path)) \(c)"
        phase = .working("Записываю настройки…")
        Task.detached {
            let r = Shell.runAsAdmin(cmd)
            await MainActor.run {
                try? FileManager.default.removeItem(at: tmp)
                if r.status != 0 { self.phase = .failed(r.output); return }
                self.loadTuning()
                self.phase = .done("Сохранено. Перезапусти \(proc) (Minecraft — полностью, вместе с лаунчером), чтобы настройки подхватились.")
            }
        }
    }

    // MARK: - Patched plugin

    static let pluginBackupDir = "/Library/NullMoth/plugin-backup"
    /// The plugin built from fixed-2.0.0 that build.sh copies into the app, if it was there at build time.
    static var embeddedPlugin: URL? { Bundle.main.url(forResource: "NVMTLDriver-fixed", withExtension: nil) }

    /// Replaces only the plugin binary, keeping the installed one for "restore". The bundle is re-signed ad hoc,
    /// as the release signs it.
    func installPlugin(from file: URL) {
        let probe = Shell.run("/usr/bin/file", ["-b", file.path]).output
        guard probe.contains("Mach-O 64-bit bundle x86_64") else { phase = .failed("Это не плагин x86_64 (\(probe.trimmingCharacters(in: .whitespacesAndNewlines)))"); return }
        guard let data = FileManager.default.contents(atPath: file.path), data.range(of: Data("NVMTLDevice".utf8)) != nil else {
            phase = .failed("В файле нет NVMTLDevice: это не NVMTLDriver"); return
        }
        guard info.installedVersion == "2.0.0" else {
            phase = .failed("Исправленный плагин собран из исходников 2.0.0. Сначала установи драйвер 2.0.0 и перезагрузись (сейчас: \(info.installedVersion ?? "версия неизвестна — нажми «Узнать»")).")
            return
        }
        let B = "/Library/GPUBundles/NVMTLDriver.bundle", bin = Tuning.pluginBinary, bk = Self.pluginBackupDir
        let cmd = """
        set -e; mkdir -p \(bk); chmod 700 \(bk)
        [ -f \(bk)/NVMTLDriver.original ] || cp -p \(bin) \(bk)/NVMTLDriver.original
        cp \(Shell.quote(file.path)) \(bin).new; chown root:wheel \(bin).new; chmod 755 \(bin).new; mv -f \(bin).new \(bin)
        /usr/bin/codesign --force -s - \(B) 2>&1
        /usr/bin/shasum -a 256 \(bin) | cut -c1-64 > \(bk)/installed-patched
        echo installed
        """
        log = ""
        phase = .working("Ставлю исправленный плагин…")
        Task.detached {
            let r = Shell.runAsAdmin(cmd)
            await MainActor.run {
                self.log = r.output
                if r.status != 0 { self.phase = .failed("Не удалось: \(r.output)"); return }
                self.loadTuning()
                self.needsReboot = true
                self.phase = .done("Плагин заменён (оригинал сохранён в \(bk)). Перезагрузись, чтобы WindowServer и приложения взяли новый.")
            }
        }
    }

    /// Puts the original back, but only over the binary this updater installed: a driver update since then already
    /// replaced it with a newer official one.
    func restorePlugin() {
        let B = "/Library/GPUBundles/NVMTLDriver.bundle", bin = Tuning.pluginBinary, bk = Self.pluginBackupDir
        let cmd = """
        [ -f \(bk)/NVMTLDriver.original ] || { echo "нет резервной копии"; exit 3; }
        now=$(/usr/bin/shasum -a 256 \(bin) | cut -c1-64)
        if [ "$now" != "$(cat \(bk)/installed-patched 2>/dev/null)" ]; then echo "плагин уже заменён обновлением драйвера; откат не нужен"; rm -rf \(bk); exit 0; fi
        cp -p \(bk)/NVMTLDriver.original \(bin).new && mv -f \(bin).new \(bin) && /usr/bin/codesign --force -s - \(B) 2>&1 && rm -rf \(bk) && echo restored
        """
        phase = .working("Возвращаю оригинальный плагин…")
        Task.detached {
            let r = Shell.runAsAdmin(cmd)
            await MainActor.run {
                self.log = r.output
                if r.status != 0 { self.phase = .failed(r.output); return }
                self.loadTuning()
                self.needsReboot = r.output.contains("restored")
                self.phase = .done(r.output.contains("restored") ? "Оригинальный плагин возвращён. Перезагрузись." : r.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
