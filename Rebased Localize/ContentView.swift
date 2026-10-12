import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = LocalizeModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.isScanning || !model.sources.isEmpty {
                    pluginCard
                } else {
                    ContentUnavailableView {
                        Label(model.busy ? "正在寻找语言插件" : "未发现语言插件", systemImage: "magnifyingglass")
                    } description: {
                        Text("自动检查 Applications、用户应用目录、Toolbox 和已注册的 JetBrains IDE。")
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                outputCard
                if let result = model.result { success(result) }
                if !model.notices.isEmpty {
                    DisclosureGroup("扫描提示（\(model.notices.count)）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.notices, id: \.self) { Text($0).textSelection(.enabled) }
                        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
            }.padding(30).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.busy { Button("取消", action: model.cancel) }
                Button(action: model.requestExport) { Label("导出插件 ZIP", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canExport)
            }.padding(.horizontal, 30).padding(.vertical, 16).background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button(action: model.scan) { Label("重新扫描", systemImage: "arrow.clockwise") }.disabled(model.busy)
            }
        }
        .frame(width: 820, height: 760)
        .task { model.initialize() }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("目标构建号在声明范围外", isPresented: $model.showOutsideConfirmation) {
            Button("取消", role: .cancel) {}
            Button("仍然导出") { model.export(allowOutside: true) }
        } message: {
            Text("目标构建不在插件声明的构建范围内。继续导出会把描述符中的构建范围改写为覆盖目标构建（其余内容保持原样），实际兼容性仍由 IDE 安装时检查。")
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("BrandMark")
                .resizable().interpolation(.high)
                .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 6) {
                Text("导出语言插件").font(.largeTitle.bold())
                Text("提取 JetBrains IDE 语言包，为 Rebased 生成可安装的插件 ZIP。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
    private var pluginCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("界面语言").font(.caption).foregroundStyle(.secondary)
                        NativeDropdown(label: "界面语言",
                                       options: model.languages.map { DropdownOption(id: $0, title: languageName($0)) },
                                       selection: Binding(get: { model.locale }, set: { model.setLanguage($0) }),
                                       scanning: model.isScanning, enabled: !model.busy || model.isScanning)
                            .frame(width: 180, height: 28, alignment: .leading)
                    }
                    Divider().frame(height: 44)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("语言包来源").font(.caption).foregroundStyle(.secondary)
                        NativeDropdown(label: "语言包来源",
                                       options: model.sources.map { DropdownOption(id: $0.id, title: $0.appName + " · " + safeLabel($0.descriptor.version)) },
                                       selection: Binding(get: { model.selectedID ?? "" }, set: { model.selectSource($0) }),
                                       scanning: model.isScanning, enabled: !model.busy || model.isScanning)
                            .frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let plugin = model.selected {
                    Divider()
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: plugin.app.path))
                            .resizable().frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plugin.appName).font(.headline)
                            Text(safeLabel(plugin.app.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("语言包版本 " + safeLabel(plugin.descriptor.version)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        compatibilityBadge(plugin.descriptor.compatibility(with: model.targetBuild))
                    }
                    HStack(alignment: .top, spacing: 28) {
                        value("目标 IDE", model.targetName)
                        value("目标构建", model.targetBuild.isEmpty ? "未检测到" : model.targetBuild)
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .top, spacing: 28) {
                        value("最低构建", plugin.descriptor.since.isEmpty ? "未声明" : plugin.descriptor.since)
                        value("最高构建", plugin.descriptor.until.isEmpty ? "未声明" : plugin.descriptor.until)
                        if !plugin.descriptor.strictUntil.isEmpty { value("严格上限", plugin.descriptor.strictUntil) }
                        Spacer(minLength: 0)
                    }
                    compatibilityHint(plugin)
                    DisclosureGroup("插件详情") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("插件 ID：" + safeLabel(plugin.descriptor.id))
                            Text("来源构建：" + safeLabel(plugin.build))
                            Text("插件目录：" + safeLabel(plugin.directory.path))
                            if !plugin.descriptor.dependencies.isEmpty {
                                Text("必需依赖：" + plugin.descriptor.dependencies.map(safeLabel).joined(separator: "、"))
                            }
                        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.caption)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func compatibilityHint(_ plugin: LanguagePlugin) -> some View {
        let state = plugin.descriptor.compatibility(with: model.targetBuild)
        let hint: String
        if model.targetBuild.hasSuffix("SNAPSHOT") {
            hint = "SNAPSHOT 构建号按 JetBrains 规则高于同号正式版。若原范围不覆盖该构建，导出时会自动改写构建范围；实际兼容性由 IDE 安装时检查。"
        } else if model.targetBuild.isEmpty {
            hint = "未自动读取到 Rebased 构建号。仍可导出语言包，由目标 IDE 检查兼容性。"
        } else if state == .outside {
            hint = "目标构建号超出插件声明范围，确认后导出时会把构建范围改写为覆盖目标构建。"
        } else {
            hint = "仅比较构建范围，实际依赖与运行兼容性由目标 IDE 最终检查。"
        }
        return Label(hint, systemImage: state == .outside ? "exclamationmark.triangle" : "info.circle")
            .font(.caption).foregroundStyle(state == .outside ? Color.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var outputCard: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("保存位置").font(.headline)
                    Text(safeLabel(model.output.path)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Text("自动创建文件夹，每次生成独立 ZIP。").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("更改…", action: model.chooseOutput).disabled(model.busy)
            }.padding(16)
        }
    }
    private func success(_ result: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ZIP 已导出并校验", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                Spacer()
                Button("在 Finder 中显示", action: model.reveal)
            }
            Text(result.url.lastPathComponent).font(.callout.monospaced()).textSelection(.enabled)
            if let range = result.patchedRange {
                Text("已改写构建范围：\(range)（其余文件保持原样）").font(.caption).foregroundStyle(.orange)
            }
            Text("\(result.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("SHA-256 校验值") {
                HStack {
                    Text(result.sha256).font(.caption2.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("复制", action: model.copyChecksum).controlSize(.small)
                }.padding(.top, 6)
            }.font(.caption)
            Divider()
            Text("手动安装：目标 IDE → Settings / Preferences → Plugins → 齿轮菜单 → Install Plugin from Disk。按提示重启并选择界面语言。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(safeLabel(text)).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
    private func compatibilityBadge(_ state: Compatibility) -> some View {
        let color: Color = state == .matching ? .green : state == .outside ? .orange : .secondary
        return Text(state.rawValue).font(.caption).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6).background(color.opacity(0.1), in: Capsule())
    }
    private func languageName(_ locale: String) -> String {
        switch locale {
        case "zh-CN", "zh": "简体中文"
        case "zh-TW": "繁體中文"
        case "ja": "日本語"
        case "ko": "한국어"
        default: Locale.current.localizedString(forIdentifier: locale) ?? locale
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
