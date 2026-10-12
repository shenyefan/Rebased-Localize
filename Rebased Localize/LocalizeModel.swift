import AppKit
import SwiftUI
import Combine

@MainActor
final class LocalizeModel: ObservableObject {
    @Published var plugins: [LanguagePlugin] = []
    @Published var locale = ""
    @Published var selectedID: String?
    @Published var targetBuild = ""
    @Published var targetName = "Rebased"
    @Published var output: URL
    @Published var busy = false
    @Published var isScanning = false
    @Published var status = "正在寻找 JetBrains IDE"
    @Published var notices: [String] = []
    @Published var errorMessage: String?
    @Published var result: ExportResult?
    @Published var showOutsideConfirmation = false
    private let service = PluginService()
    private var operation: Task<Void, Never>?
    private var initialized = false
    private var manuallySelectedLanguage = false
    private var manuallySelectedSource = false

    init() {
        output = Self.userHome.appendingPathComponent("Downloads/Rebased Localize", isDirectory: true)
    }
    private static var userHome: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    var languages: [String] {
        Array(Set(plugins.map { $0.descriptor.locale })).sorted { a, b in
            if a == "zh-CN" { return b != "zh-CN" }
            if b == "zh-CN" { return false }
            return a < b
        }
    }
    var sources: [LanguagePlugin] {
        plugins.filter { $0.descriptor.locale == locale }.sorted {
            if $0.appName == $1.appName { return $0.directory.path < $1.directory.path }
            return $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
        }
    }

    var selected: LanguagePlugin? { sources.first { $0.id == selectedID } }
    var validTarget: Bool { targetBuild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPlatformBuild(targetBuild) }
    var canExport: Bool { selected != nil && !busy && validTarget }
    var ideCount: Int { Set(plugins.map { $0.app.path }).count }
    private var roots: [URL] {
        var roots = [URL(fileURLWithPath: "/Applications"), Self.userHome.appendingPathComponent("Applications"),
                     Self.userHome.appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps")]
        // Launch Services 补充已注册的自定义安装位置，无需用户选择 IDE。
        for id in ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.WebStorm", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.CLion", "com.jetbrains.PhpStorm", "com.jetbrains.GoLand", "com.jetbrains.rider", "com.jetbrains.datagrip", "com.jetbrains.rubymine", "com.jetbrains.dataspell", "com.jetbrains.RustRover"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { roots.append(url) }
        }
        return roots
    }
    func initialize() {
        guard !initialized else { return }
        initialized = true
        scan()
    }
    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "更改输出位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = output
        if panel.runModal() == .OK, let url = panel.url { output = url }
    }
    func setLanguage(_ value: String) {
        manuallySelectedLanguage = true
        manuallySelectedSource = false
        locale = value
        selectedID = sources.first?.id
    }
    func selectSource(_ value: String) {
        manuallySelectedSource = true
        selectedID = value
    }
    func scan() {
        guard !busy else { return }
        busy = true
        isScanning = true
        plugins = []
        notices = []
        status = "正在寻找 JetBrains IDE 与语言插件…"
        let locations = roots
        let targetLocations = [URL(fileURLWithPath: "/Applications/Rebased.app"), Self.userHome.appendingPathComponent("Applications/Rebased.app")]
        operation = Task {
            do {
                let service = self.service
                let detected = try await service.detectTarget(at: targetLocations)
                targetBuild = detected
                let scan = try await service.scan(roots: locations, onDiscovery: { @MainActor [weak self] discovered in
                    guard let self else { return }
                    self.plugins.append(discovered)
                    if !self.manuallySelectedLanguage { self.locale = self.languages.first ?? "" }
                    if !self.manuallySelectedSource { self.selectedID = self.sources.first?.id }
                    self.status = "扫描中 · 已发现 \(self.ideCount) 个 IDE · \(self.plugins.count) 个语言包"
                })
                notices = scan.notices
                if !languages.contains(locale) { locale = languages.first ?? "" }
                if !sources.contains(where: { $0.id == selectedID }) { selectedID = sources.first?.id; manuallySelectedSource = false }
                status = plugins.isEmpty ? "未发现可导出的语言插件" : "已发现 \(ideCount) 个 IDE · \(languages.count) 种语言"
            } catch is CancellationError { status = "扫描已取消" }
            catch { errorMessage = error.localizedDescription; status = "扫描失败" }
            busy = false
            isScanning = false
            operation = nil
        }
    }
    func requestExport() {
        guard canExport, let selected else { return }
        if selected.descriptor.compatibility(with: targetBuild) == .outside { showOutsideConfirmation = true }
        else { export(allowOutside: false) }
    }
    func export(allowOutside: Bool) {
        guard canExport, let selected else { return }
        let target = targetBuild, directory = output
        busy = true
        result = nil
        status = "正在复制、打包并校验全部文件…"
        operation = Task {
            do {
                let exported = try await service.export(selected, into: directory, target: target, allowOutside: allowOutside)
                result = exported
                status = exported.patchedRange.map { "导出完成 · 构建范围已改写为 \($0)" } ?? "导出完成 · 全部文件校验通过"
            } catch is CancellationError { status = "导出已取消，暂存文件已清理" }
            catch { errorMessage = error.localizedDescription; status = "导出失败" }
            busy = false
            isScanning = false
            operation = nil
        }
    }
    func cancel() { operation?.cancel() }
    func reveal() { if let result { NSWorkspace.shared.activateFileViewerSelecting([result.url]) } }
    func copyChecksum() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.sha256, forType: .string)
    }
}
