import Foundation

actor DiscoveryProbe {
    var count = 0
    var completed = false
    var deliveredBeforeCompletion = true
    func discovered() { count += 1; deliveredBeforeCompletion = deliveredBeforeCompletion && !completed }
    func finish() -> Bool { completed = true; return count > 0 && deliveredBeforeCompletion }
}

@main
struct CoreChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks: [String] = []
        func check(_ name: String, _ pass: Bool) throws {
            guard pass else { throw LocalizeError("FAIL: " + name) }
            checks.append(name)
            print("PASS " + name)
        }
        try check("构建号前缀与补零比较", BuildNumber("IC-251.20")! == BuildNumber("251.20.0")!)
        try check("无效构建号拒绝", BuildNumber("251.*") == nil && BuildNumber("abc") == nil)
        try check("SNAPSHOT 构建号可以识别", isPlatformBuild("IC-262.10968.SNAPSHOT"))
        try check("SNAPSHOT 高于同号正式版且低于下一线",
                  BuildNumber("IC-262.10968.SNAPSHOT")! > BuildNumber("262.10968.63")!
                  && BuildNumber("262.10968.SNAPSHOT")! < BuildNumber("262.10969")!)
        let service = PluginService()
        let probe = DiscoveryProbe()
        let scan = try await service.scan(roots: [root.appendingPathComponent("Applications 测试")], onDiscovery: { _ in await probe.discovered() })
        try check("扫描完成前即发送发现事件", await probe.finish())
        try check("扫描带空格和中文的 IDE 路径", scan.plugins.count == 1)
        let plugin = scan.plugins[0]
        try check("真实平台构建优先于产品版本", plugin.build == "WS-251.20.123")
        try check("从 deflate JAR 读取描述符", plugin.descriptor.id == "com.intellij.zh" && plugin.descriptor.locale == "zh-CN")
        try check("最低构建拦截", plugin.descriptor.compatibility(with: "251.9") == .outside)
        try check("通配符上限接受补丁版本", plugin.descriptor.compatibility(with: "IC-251.99999.123") == .matching)
        try check("通配符上限拦截新分支", plugin.descriptor.compatibility(with: "252.1") == .outside)
        try check("目标构建未知提示", plugin.descriptor.compatibility(with: "") == .unknown)
        try check("通配范围覆盖同线 SNAPSHOT", plugin.descriptor.compatibility(with: "IC-251.20.SNAPSHOT") == .matching)
        let concrete = PluginDescriptor(id: "com.intellij.zh", version: "262.10968.63", locale: "zh-CN", label: "Chinese",
                                        since: "262.10968.63", until: "262.10968.63", strictUntil: "", dependencies: [], data: Data())
        try check("具体上限拦截同线 SNAPSHOT", concrete.compatibility(with: "IC-262.10968.SNAPSHOT") == .outside)
        let patch = DescriptorPatch.compute(descriptor: concrete, target: "IC-262.10968.SNAPSHOT")
        try check("改写为覆盖目标构建的通配上限", patch == DescriptorPatch(since: "262.10968.63", until: "262.10968.*"))
        let rewrittenXML = try patch!.apply(to: Data("<idea-plugin><idea-version since-build='262.10968.63' until-build='262.10968.63'/></idea-plugin>".utf8))
        try check("改写 idea-version 声明",
                  String(decoding: rewrittenXML, as: UTF8.self).contains("since-build=\"262.10968.63\"")
                  && String(decoding: rewrittenXML, as: UTF8.self).contains("until-build=\"262.10968.*\""))
        let idea = LanguagePlugin(directory: plugin.directory, app: plugin.app, appName: "IntelliJ IDEA", build: plugin.build, descriptor: plugin.descriptor)
        try check("IDE 名称按字母排序 IDEA 在 WebStorm 前", idea.appName.localizedStandardCompare(plugin.appName) == .orderedAscending)
        let snapshotApp = root.appendingPathComponent("snapshot/Rebased.app/Contents/Resources")
        try FileManager.default.createDirectory(at: snapshotApp, withIntermediateDirectories: true)
        try "IC-262.10968.SNAPSHOT".write(to: snapshotApp.appendingPathComponent("build.txt"), atomically: true, encoding: .utf8)
        try check("读取并保留真实 SNAPSHOT 构建", try PluginService.build(at: snapshotApp.deletingLastPathComponent().deletingLastPathComponent()) == "IC-262.10968.SNAPSHOT")
        let original = try inventory(plugin.directory)
        let output = root.appendingPathComponent("output")
        let result = try await service.export(plugin, into: output, target: "IC-251.20.123", allowOutside: false)
        try check("导出并完整校验原生 ZIP", FileManager.default.fileExists(atPath: result.url.path))
        let reader = try ZIPReader(url: result.url)
        try check("唯一顶级目录与精确条目清单", Set(reader.entries.map(\.name)) == Set(["localization-zh/"] + original.keys.map { "localization-zh/" + $0 }))
        try check("保留隐藏文件与空目录", reader.entries.contains { $0.name == "localization-zh/.hidden" } && reader.entries.contains { $0.name == "localization-zh/resources/empty/" })
        try check("来源插件完全未修改", try inventory(plugin.directory) == original)
        try check("ZIP SHA-256 已生成", result.sha256.count == 64)
        let newFolder = root.appendingPathComponent("nested/new-output")
        let snapshotExport = try await service.export(plugin, into: newFolder, target: "IC-251.20.SNAPSHOT", allowOutside: false)
        try check("默认新建输出目录且支持 SNAPSHOT 导出", FileManager.default.fileExists(atPath: newFolder.path))
        try check("范围内 SNAPSHOT 原样导出", snapshotExport.patchedRange == nil)
        let again = try await service.export(plugin, into: output, target: "", allowOutside: false)
        try check("重复导出使用独立文件名", again.url != result.url)
        var blocked = false
        do { _ = try await service.export(plugin, into: output, target: "252.1", allowOutside: false) } catch { blocked = true }
        try check("服务层拦截不兼容导出", blocked)
        let rebased = try await service.export(plugin, into: output, target: "252.1", allowOutside: true)
        try check("确认后导出并改写构建范围", rebased.patchedRange == "251.10 – 252.1.*")
        let outer = try ZIPReader(url: rebased.url)
        guard let jarEntry = outer.entries.first(where: { $0.name == "localization-zh/lib/main.jar" })
        else { throw LocalizeError("FAIL: 导出 ZIP 缺少改写 JAR") }
        var jarBytes = Data()
        try outer.consume(jarEntry) { jarBytes.append($0) }
        let rebuiltJar = root.appendingPathComponent("output/rebuilt-main.jar")
        try jarBytes.write(to: rebuiltJar)
        let inner = try ZIPReader(url: rebuiltJar)
        for entry in inner.entries { try inner.consume(entry) { _ in } }
        let rewrittenDescriptor = String(decoding: try inner.descriptorData() ?? Data(), as: UTF8.self)
        try check("重建 JAR 保留其余条目并改写 idea-version",
                  inner.entries.contains { $0.name == "messages/test.properties" }
                  && rewrittenDescriptor.contains("since-build=\"251.10\"")
                  && rewrittenDescriptor.contains("until-build=\"252.1.*\""))
        blocked = false
        do { _ = try await service.export(plugin, into: plugin.app, target: "", allowOutside: false) } catch { blocked = true }
        try check("拒绝向应用内部输出", blocked)
        for name in ["symlink", "ambiguous", "corrupt", "dtd"] {
            let result = try await service.scan(roots: [root.appendingPathComponent(name)])
            try check("拒绝异常来源 " + name, result.plugins.isEmpty && !result.notices.isEmpty)
        }
        for name in ["traversal", "absolute", "backslash", "duplicate"] {
            var rejected = false
            do { _ = try ZIPReader(url: root.appendingPathComponent(name + ".zip")) } catch { rejected = true }
            try check("拒绝不安全 ZIP " + name, rejected)
        }
        let broken = try ZIPReader(url: root.appendingPathComponent("crc.zip"))
        blocked = false
        do { try broken.consume(broken.entries[0]) { _ in } } catch { blocked = true }
        try check("损坏内容 CRC 拦截", blocked)
        let canceled = Task { try await service.export(plugin, into: output, target: "", allowOutside: false) }
        canceled.cancel()
        blocked = false
        do { _ = try await canceled.value } catch is CancellationError { blocked = true }
        try check("后台任务支持取消", blocked)
        let contents = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        try check("失败取消均清理暂存目录", !contents.contains { $0.lastPathComponent.hasPrefix(".rebased-localize-") })
        print("\nPASS: \(checks.count) checks\nZIP: \(result.url.path)")
    }
}
