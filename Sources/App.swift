import AppKit
import SwiftUI

@main
struct NullMothUpdaterApp: App {
    @StateObject private var model = UpdaterModel()
    @StateObject private var efi = EFIModel()

    var body: some Scene {
        WindowGroup("NullMoth Updater") {
            ContentView()
                .environmentObject(model)
                .environmentObject(efi)
                .frame(minWidth: 820, minHeight: 700)
                .onAppear { model.refresh(); efi.refresh() }
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var m: UpdaterModel
    @State private var confirmUninstall = false
    @State private var confirmReboot = false
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusCard()
            TabView {
                VStack(alignment: .leading, spacing: 12) {
                    ReleaseCard()
                    actions
                }
                .padding(10)
                .tabItem { Text("Драйвер") }
                TuningCard()
                    .padding(10)
                    .tabItem { Text("Игры и производительность") }
                EFITab()
                    .padding(10)
                    .tabItem { Text("EFI") }
            }
            .frame(minHeight: 300)
            PhaseBanner()
            LogView()
        }
        .padding(18)
        .alert("Удалить драйвер?", isPresented: $confirmUninstall) {
            Button("Удалить", role: .destructive) { m.uninstall() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будет запущен uninstall.sh из пакета. Экран после перезагрузки вернётся на базовый режим без ускорения. Настройки OpenCore (boot-args) не меняются.")
        }
        .alert("Перезагрузить сейчас?", isPresented: $confirmReboot) {
            Button("Перезагрузить") { m.reboot() }
            Button("Позже", role: .cancel) {}
        } message: { Text("Сохрани открытые документы.") }
        .alert("Очистить кэш шейдеров?", isPresented: $confirmClear) {
            Button("Очистить") { m.clearShaderCache() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Помогает при артефактах после обновления. Первый запуск игр и WindowServer будет медленнее, пока шейдеры собираются заново.")
        }
    }

    private func pickPlugin() {
        let panel = NSOpenPanel()
        panel.title = "Файл NVMTLDriver (собранный из fixed-2.0.0)"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { m.installPlugin(from: url) }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                m.install(dryRun: false)
            } label: {
                Label(m.info.bundleInstalled ? "Обновить / переустановить" : "Установить", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(m.busy || m.selectedRelease == nil)

            Button("Проверить без изменений") { m.install(dryRun: true) }
                .disabled(m.busy || m.selectedRelease == nil)
                .help("Запускает install.sh с CHECK=1: тестовая сборка kernel collection, ничего не меняется")

            Menu("Ещё") {
                Button("Узнать установленную версию (пароль)") { m.readVersionAsAdmin() }
                Button("Очистить кэш шейдеров…") { confirmClear = true }
                Divider()
                Button("Установить исправленный плагин (встроенный)") {
                    if let u = UpdaterModel.embeddedPlugin { m.installPlugin(from: u) }
                }
                .disabled(UpdaterModel.embeddedPlugin == nil)
                Button("Установить исправленный плагин из файла…") { pickPlugin() }
                Button("Вернуть оригинальный плагин") { m.restorePlugin() }
                Button("Открыть папку логов") { m.openLogs() }
                Divider()
                Button("Удалить драйвер…") { confirmUninstall = true }
            }
            .disabled(m.busy)
            .fixedSize()

            Spacer()

            if case .downloading = m.phase {
                Button("Отменить загрузку") { m.cancelDownload() }
            }
            Button {
                confirmReboot = true
            } label: { Label("Перезагрузить", systemImage: "restart") }
                .tint(m.needsReboot ? .orange : nil)
                .buttonStyle(.bordered)
                .disabled(m.busy)
        }
    }
}

struct StatusCard: View {
    @EnvironmentObject var m: UpdaterModel

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Видеокарта", m.info.gpu + (m.info.vram.isEmpty ? "" : " · \(m.info.vram)"))
                row("macOS", m.info.macOS.isEmpty ? "—" : "\(m.info.macOS) (\(m.info.build))")
                GridRow {
                    Text("Кексты").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: m.info.driverLoaded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(m.info.driverLoaded ? .green : .orange)
                        Text(m.info.driverLoaded ? "загружены все 4" :
                                "загружено \(m.info.loadedKexts.filter { SystemInfo.expectedKexts.contains($0) }.count) из 4")
                    }
                }
                GridRow {
                    Text("Версия драйвера").foregroundStyle(.secondary)
                    HStack {
                        Text(m.info.installedVersion ?? (m.info.bundleInstalled ? "неизвестна" : "не установлен"))
                        if m.info.installedVersion == nil && m.info.bundleInstalled {
                            Button("Узнать") { m.readVersionAsAdmin() }.controlSize(.small).disabled(m.busy)
                        }
                    }
                }
                if m.info.onBattery {
                    GridRow {
                        Text("Питание").foregroundStyle(.secondary)
                        Label("Ноутбук на батарее: мобильная GPU урезана по мощности, FPS в играх будет сильно ниже. Подключи зарядку.",
                              systemImage: "battery.25")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Система")
                if m.loadingInfo { ProgressView().controlSize(.small) }
                Spacer()
                Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(m.busy)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

struct ReleaseCard: View {
    @EnvironmentObject var m: UpdaterModel

    var body: some View {
        GroupBox {
            if m.releases.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Проверяю релизы на GitHub…") }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Версия", selection: $m.selected) {
                            ForEach(m.releases, id: \.version) { r in
                                Text("\(r.version)  ·  \(r.published)\(r.version == m.latest?.version ? "  (новейшая)" : "")").tag(r.version)
                            }
                        }
                        .frame(maxWidth: 360)
                        .disabled(m.busy)
                        Spacer()
                        if m.updateAvailable {
                            Label("Доступно обновление", systemImage: "sparkles").foregroundStyle(.blue)
                        } else if m.info.installedVersion != nil {
                            Label("Установлена новейшая", systemImage: "checkmark.seal").foregroundStyle(.green)
                        }
                    }
                    if let r = m.selectedRelease {
                        ScrollView {
                            Text(r.notes)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 150)
                        Text("SHA-256 \(r.sha256)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } label: { Text("Релизы") }
    }
}

struct PhaseBanner: View {
    @EnvironmentObject var m: UpdaterModel

    var body: some View {
        switch m.phase {
        case .idle:
            EmptyView()
        case .working(let s):
            HStack { ProgressView().controlSize(.small); Text(s) }
        case .downloading(let f, let s):
            VStack(alignment: .leading) {
                ProgressView(value: min(max(f, 0), 1))
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
        case .done(let s):
            Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let s):
            Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var m: UpdaterModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(m.log.isEmpty ? "Здесь будет вывод install.sh" : m.log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(m.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .onChange(of: m.log) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct TuningCard: View {
    @EnvironmentObject var m: UpdaterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Программа:")
                TextField("java", text: $m.tuneProcess)
                    .frame(width: 160)
                    .onSubmit { m.loadTuning() }
                Text("(имя процесса; Minecraft Java — «java»)").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(Tuning.knobs) { k in
                Toggle(isOn: Binding(get: { m.tuneOn.contains(k.id) },
                                     set: { on in if on { m.tuneOn.insert(k.id) } else { m.tuneOn.remove(k.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.title)
                        Text(k.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Button("Сохранить для «\(m.tuneProcess)»") { m.applyTuning() }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.busy)
                Button("Перечитать") { m.loadTuning() }.disabled(m.busy)
                Spacer()
            }
            if !m.pluginPerApp {
                Label("Установленный плагин не понимает настройки для одной программы: строки будут записаны, но включатся только после установки исправленного плагина (Ещё → Установить исправленный плагин (встроенный)).",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Плагин поддерживает настройки для одной программы. WindowServer и другие приложения их не видят.",
                      systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
