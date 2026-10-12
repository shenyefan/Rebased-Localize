import Foundation
import CryptoKit
import Darwin

struct LocalizeError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private let sizeLimit: UInt64 = 2 * 1024 * 1024 * 1024
private let xmlLimit = 2 * 1024 * 1024

func safeLabel(_ value: String) -> String {
    String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
}

func isPlatformBuild(_ raw: String) -> Bool {
    BuildNumber(raw) != nil
}

struct BuildNumber: Comparable, Sendable {
    // JetBrains 构建号比较中 SNAPSHOT 分量按字符串比较大于任何数字分量（IC-262.10968.SNAPSHOT > 262.10968.63），
    // 这里以 Int.max 表示该分量。
    static let snapshot = Int.max
    let parts: [Int]
    init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[A-Za-z]+-", with: "", options: .regularExpression)
        let snapshotTail = value.hasSuffix(".SNAPSHOT")
        let core = snapshotTail ? String(value.dropLast(".SNAPSHOT".count)) : value
        guard core.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil else { return nil }
        var parsed = core.split(separator: ".").compactMap { Int($0) }
        guard parsed.count == core.split(separator: ".").count else { return nil }
        if snapshotTail { parsed.append(Self.snapshot) }
        parts = parsed
    }
    var numericForm: String { parts.filter { $0 != Self.snapshot }.map(String.init).joined(separator: ".") }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

enum Compatibility: String, Sendable {
    case matching = "构建范围内", unknown = "兼容性未知", outside = "构建范围外"
    var rank: Int { switch self { case .matching: 0; case .unknown: 1; case .outside: 2 } }
}

struct PluginDescriptor: Equatable, Sendable {
    let id: String
    let version: String
    let locale: String
    let label: String
    let since: String
    let until: String
    let strictUntil: String
    let dependencies: [String]
    let data: Data

    func compatibility(with target: String) -> Compatibility {
        guard let target = BuildNumber(target) else { return .unknown }
        if since.isEmpty { /* 未声明下限 */ }
        else if let lower = BuildNumber(since) { if target < lower { return .outside } }
        else { return .unknown }
        let upper = strictUntil.isEmpty ? until : strictUntil
        if upper.isEmpty { return .matching }
        if upper.hasSuffix(".*") {
            guard let prefix = BuildNumber(String(upper.dropLast(2))) else { return .unknown }
            for i in prefix.parts.indices {
                let part = i < target.parts.count ? target.parts[i] : 0
                if part > prefix.parts[i] { return .outside }
                if part < prefix.parts[i] { return .matching }
            }
            return .matching
        }
        guard let upper = BuildNumber(upper) else { return .unknown }
        return upper < target ? .outside : .matching
    }
}

// 目标构建超出声明范围时，导出前改写 idea-version 使其覆盖目标构建。
// 上限放宽为目标所在线的通配符（如 262.10968.SNAPSHOT → 262.10968.*），可同时覆盖同线正式版与快照版；
// strict-until-build 一并移除，避免其继续限制安装。
struct DescriptorPatch: Equatable, Sendable {
    let since: String
    let until: String

    static func compute(descriptor: PluginDescriptor, target: String) -> DescriptorPatch? {
        guard let goal = BuildNumber(target), descriptor.compatibility(with: target) == .outside else { return nil }
        var since = descriptor.since
        if let lower = BuildNumber(descriptor.since), goal < lower { since = goal.numericForm }
        var until = descriptor.until
        let upper = descriptor.strictUntil.isEmpty ? descriptor.until : descriptor.strictUntil
        if upper.hasSuffix(".*") {
            if let prefix = BuildNumber(String(upper.dropLast(2))) {
                for i in prefix.parts.indices {
                    let part = i < goal.parts.count ? goal.parts[i] : 0
                    if part > prefix.parts[i] { until = goal.numericForm + ".*"; break }
                    if part < prefix.parts[i] { break }
                }
            }
        } else if let top = BuildNumber(upper), top < goal {
            until = goal.numericForm + ".*"
        }
        guard since != descriptor.since || until != descriptor.until else { return nil }
        return DescriptorPatch(since: since, until: until)
    }

    func apply(to xml: Data) throws -> Data {
        guard let text = String(data: xml, encoding: .utf8) else { throw LocalizeError("描述符不是 UTF-8 编码，无法改写。") }
        let expression = try NSRegularExpression(pattern: "<idea-version\\b[^>]*>")
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range, in: text) else {
            throw LocalizeError("描述符缺少唯一的 idea-version 声明。")
        }
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var element = "<idea-version"
        if !since.isEmpty { element += " since-build=\"\(escaped(since))\"" }
        if !until.isEmpty { element += " until-build=\"\(escaped(until))\"" }
        element += " />"
        var patched = text
        patched.replaceSubrange(range, with: element)
        return Data(patched.utf8)
    }
}

private final class DescriptorParser: NSObject, XMLParserDelegate {
    var stack: [String] = []
    var current = ""
    var fields: [String: String] = [:]
    var versionRange: [String: String] = [:]
    var languages: [[String: String]] = []
    var dependencies: [String] = []
    var requiredDependency = false
    var validRoot = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if stack.isEmpty { validRoot = elementName == "idea-plugin" }
        stack.append(elementName)
        current = ""
        if stack.count == 2 && elementName == "idea-version" { versionRange = attributes }
        if elementName == "languageBundle" { languages.append(attributes) }
        if stack.count == 2 && elementName == "depends" { requiredDependency = attributes["optional"] != "true" }
        if elementName == "plugin", stack.dropLast().last == "dependencies", let id = attributes["id"] { dependencies.append(id) }
        if elementName == "module", stack.dropLast().last == "dependencies", let name = attributes["name"] { dependencies.append(name) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { current += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.count == 2 {
            if ["id", "name", "version"].contains(elementName) { fields[elementName] = value }
            if elementName == "depends", requiredDependency, !value.isEmpty { dependencies.append(value) }
        }
        _ = stack.popLast()
        current = ""
    }
    static func read(_ data: Data) throws -> PluginDescriptor? {
        guard data.count <= xmlLimit else { throw LocalizeError("plugin.xml 超过 2 MiB。") }
        // 过滤 NUL 后也覆盖 UTF-16/32 编码的 DTD 标记。
        let text = String(decoding: data.filter { $0 != 0 }, as: UTF8.self).uppercased()
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw LocalizeError("插件描述符包含 DTD 或实体声明。") }
        let delegate = DescriptorParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else { throw LocalizeError("plugin.xml 无法解析。") }
        guard delegate.validRoot else { return nil }
        let locales = Set(delegate.languages.compactMap { $0["locale"] }.filter { !$0.isEmpty })
        guard !locales.isEmpty else { return nil }
        guard locales.count == 1, let locale = locales.first else { throw LocalizeError("单个插件声明多种语言，无法唯一识别。") }
        guard let name = delegate.fields["name"], !name.isEmpty,
              let version = delegate.fields["version"], !version.isEmpty else { throw LocalizeError("语言插件缺少名称或版本。") }
        let label = delegate.languages.first { $0["locale"] == locale }?["displayName"] ?? locale
        return PluginDescriptor(id: delegate.fields["id"] ?? name, version: version, locale: locale,
                                label: label, since: delegate.versionRange["since-build"] ?? "",
                                until: delegate.versionRange["until-build"] ?? "",
                                strictUntil: delegate.versionRange["strict-until-build"] ?? "",
                                dependencies: delegate.dependencies, data: data)
    }
}

// ZIP 读取仅支持标准的 store / deflate。拒绝加密、ZIP64、重复/越界条目和不安全路径。
// 不将 JAR 解压到磁盘；流式解压并检查 CRC，描述符才保留在内存。
struct ZIPReader {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressed: Int
        let size: Int
        let offset: Int
        let directory: Bool
    }
    let data: Data
    let entries: [Entry]
    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= sizeLimit else { throw LocalizeError("ZIP/JAR 超过 2 GiB。") }
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw LocalizeError("ZIP/JAR 文件不完整。") }
        var end: Int?
        for p in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try data.u32(p) == 0x06054b50, p + 22 + Int(try data.u16(p + 20)) == data.count { end = p; break }
        }
        guard let end else { throw LocalizeError("找不到 ZIP 中央目录。") }
        let count = Int(try data.u16(end + 10))
        let centralSize = Int(try data.u32(end + 12))
        let centralStart = Int(try data.u32(end + 16))
        guard try data.u16(end + 4) == 0, try data.u16(end + 6) == 0,
              try data.u16(end + 8) == UInt16(count), count != 65535,
              centralStart + centralSize == end else { throw LocalizeError("不支持分卷或 ZIP64 文件。") }
        var p = centralStart
        var parsed: [Entry] = []
        var names = Set<String>()
        var expanded: UInt64 = 0
        for _ in 0..<count {
            guard try data.u32(p) == 0x02014b50 else { throw LocalizeError("ZIP 中央目录损坏。") }
            let flags = try data.u16(p + 8), method = try data.u16(p + 10)
            let crc = try data.u32(p + 16)
            let compressed = Int(try data.u32(p + 20)), size = Int(try data.u32(p + 24))
            let length = Int(try data.u16(p + 28)), extra = Int(try data.u16(p + 30)), comment = Int(try data.u16(p + 32))
            let external = try data.u32(p + 38), local = Int(try data.u32(p + 42))
            guard flags & 1 == 0, method == 0 || method == 8, compressed != Int(UInt32.max), size != Int(UInt32.max),
                  try data.u16(p + 34) == 0, p + 46 + length + extra + comment <= end,
                  let name = String(data: try data.bytes(p + 46, length), encoding: .utf8),
                  ZIPReader.safePath(name), names.insert(name).inserted else { throw LocalizeError("ZIP 含加密、重复或不安全条目。") }
            let type = (external >> 16) & 0xf000
            guard type == 0 || type == 0x8000 || type == 0x4000 else { throw LocalizeError("ZIP 含链接或特殊文件。") }
            guard try data.u32(local) == 0x04034b50, try data.u16(local + 8) == method,
                  try data.u16(local + 6) == flags else { throw LocalizeError("ZIP 本地头与中央目录不一致。") }
            let localLength = Int(try data.u16(local + 26)), localExtra = Int(try data.u16(local + 28))
            guard try data.bytes(local + 30, localLength) == data.bytes(p + 46, length) else { throw LocalizeError("ZIP 条目名称不一致。") }
            let offset = local + 30 + localLength + localExtra
            guard offset >= 0, offset + compressed <= centralStart else { throw LocalizeError("ZIP 数据越界。") }
            expanded += UInt64(size)
            guard expanded <= sizeLimit else { throw LocalizeError("ZIP 解压总大小超过 2 GiB。") }
            parsed.append(Entry(name: name, method: method, crc: crc, compressed: compressed, size: size,
                                offset: offset, directory: name.hasSuffix("/")))
            p += 46 + length + extra + comment
        }
        guard p == end else { throw LocalizeError("ZIP 中央目录长度不一致。") }
        entries = parsed
    }
    static func safePath(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains(":") &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        !name.split(separator: "/", omittingEmptySubsequences: false).dropLast(name.hasSuffix("/") ? 1 : 0).contains { $0 == "." || $0 == ".." || $0.isEmpty }
    }
    func consume(_ entry: Entry, _ body: (Data) throws -> Void) throws {
        var checksum: uLong = 0
        var produced = 0
        func accept(_ chunk: Data) throws {
            produced += chunk.count
            guard produced <= entry.size else { throw LocalizeError("ZIP 解压大小与声明不一致。") }
            checksum = chunk.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)) }
            try body(chunk)
        }
        if entry.method == 0 {
            guard entry.compressed == entry.size else { throw LocalizeError("未压缩 ZIP 条目大小异常。") }
            var p = 0
            while p < entry.size {
                try Task.checkCancellation()
                let count = min(65536, entry.size - p)
                try accept(data.bytes(entry.offset + p, count))
                p += count
            }
        } else {
            var stream = z_stream()
            guard rl_inflate_init(&stream) == Z_OK else { throw LocalizeError("无法初始化解压。") }
            defer { inflateEnd(&stream) }
            try data.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!.advanced(by: entry.offset))
                stream.avail_in = uInt(entry.compressed)
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    try Task.checkCancellation()
                    let oldIn = stream.avail_in
                    let result = buffer.withUnsafeMutableBytes { out in
                        stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(out.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let count = buffer.count - Int(stream.avail_out)
                    if count > 0 { try accept(Data(buffer.prefix(count))) }
                    if result == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw LocalizeError("ZIP 压缩数据包含多余内容。") }
                        break
                    }
                    guard result == Z_OK, count > 0 || stream.avail_in < oldIn else { throw LocalizeError("ZIP 压缩数据损坏。") }
                }
            }
        }
        guard produced == entry.size, UInt32(checksum) == entry.crc else { throw LocalizeError("ZIP/JAR CRC 完整性校验失败。") }
    }
    func descriptorData() throws -> Data? {
        let matches = entries.filter { $0.name == "META-INF/plugin.xml" }
        guard matches.count <= 1 else { throw LocalizeError("JAR 内含重复描述符。") }
        guard let entry = matches.first else { return nil }
        guard entry.size <= xmlLimit else { throw LocalizeError("JAR 内描述符过大。") }
        var result = Data()
        try consume(entry) { result.append($0) }
        return result
    }
}

private extension Data {
    func bytes(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= self.count, count <= self.count - offset else { throw LocalizeError("ZIP 文件截断。") }
        return subdata(in: offset..<(offset + count))
    }
    func u16(_ p: Int) throws -> UInt16 {
        let b = try bytes(p, 2); return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }
    func u32(_ p: Int) throws -> UInt32 {
        let b = try bytes(p, 4); return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[b.startIndex + $1]) << ($1 * 8) }
    }
    mutating func put16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func put32(_ value: UInt32) { put16(UInt16(value & 65535)); put16(UInt16(value >> 16)) }
}

struct FileRecord: Equatable, Sendable {
    let size: UInt64
    let hash: String
    let crc: UInt32
    let directory: Bool
    let permissions: UInt16
}

private func fileDigest(_ url: URL) throws -> (String, UInt32, UInt64) {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256(), checksum: uLong = 0, total: UInt64 = 0
    while let chunk = try file.read(upToCount: 65536), !chunk.isEmpty {
        try Task.checkCancellation()
        total += UInt64(chunk.count)
        guard total <= sizeLimit else { throw LocalizeError("文件超过 2 GiB。") }
        hash.update(data: chunk)
        checksum = chunk.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)) }
    }
    return (hash.finalize().map { String(format: "%02x", $0) }.joined(), UInt32(checksum), total)
}

func inventory(_ root: URL) throws -> [String: FileRecord] {
    let fm = FileManager.default
    // 枚举器返回符号链接解析后的子路径（/tmp 下会得到 /private/tmp 前缀），
    // URL.resolvingSymlinksInPath 不解析这类系统链接，需用 realpath 对齐后再计算相对路径。
    var resolved = root.standardizedFileURL
    if let real = root.path.withCString({ realpath($0, nil) }) {
        resolved = URL(fileURLWithPath: String(cString: real))
        free(real)
    }
    let attrs = try fm.attributesOfItem(atPath: resolved.path)
    guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw LocalizeError("来源插件必须是普通目录。") }
    var traversalError: Error?
    guard let enumerator = fm.enumerator(at: resolved, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in traversalError = error; return false }) else { throw LocalizeError("无法读取插件目录。") }
    var records: [String: FileRecord] = [:]
    var total: UInt64 = 0
    for case let url as URL in enumerator {
        try Task.checkCancellation()
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw LocalizeError("插件包含链接或特殊文件：\(safeLabel(url.lastPathComponent))") }
        guard type != .typeRegular || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw LocalizeError("插件包含硬链接文件。") }
        let rel = String(url.path.dropFirst(resolved.path.count + 1)) + (type == .typeDirectory ? "/" : "")
        guard ZIPReader.safePath(rel), records.count < 60000 else { throw LocalizeError("插件文件名不安全或条目数量超过 60000。") }
        let digest = type == .typeRegular ? try fileDigest(url) : ("", UInt32(0), UInt64(0))
        total += digest.2
        guard total <= sizeLimit else { throw LocalizeError("插件总大小超过 2 GiB。") }
        records[rel] = FileRecord(size: digest.2, hash: digest.0, crc: digest.1, directory: type == .typeDirectory,
                                  permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644)
    }
    if let traversalError { throw traversalError }
    guard records.keys.contains(where: { $0.hasPrefix("lib/") && $0.hasSuffix(".jar") }) else { throw LocalizeError("插件缺少 lib 下的 JAR。") }
    return records
}

// 扫描期轻量清点：保持与 inventory 相同的安全拒绝（链接/特殊文件、硬链接、不安全路径、
// 条目数与总大小上限、lib 下必须有 JAR），但不读取文件内容；逐字节哈希只在导出时进行。
func checkPluginLayout(_ root: URL) throws {
    let fm = FileManager.default
    var resolved = root.standardizedFileURL
    if let real = root.path.withCString({ realpath($0, nil) }) {
        resolved = URL(fileURLWithPath: String(cString: real))
        free(real)
    }
    let attrs = try fm.attributesOfItem(atPath: resolved.path)
    guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw LocalizeError("来源插件必须是普通目录。") }
    var traversalError: Error?
    guard let enumerator = fm.enumerator(at: resolved, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in traversalError = error; return false }) else { throw LocalizeError("无法读取插件目录。") }
    var entries = 0
    var total: UInt64 = 0
    var hasJar = false
    for case let url as URL in enumerator {
        try Task.checkCancellation()
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw LocalizeError("插件包含链接或特殊文件：\(safeLabel(url.lastPathComponent))") }
        guard type != .typeRegular || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw LocalizeError("插件包含硬链接文件。") }
        let rel = String(url.path.dropFirst(resolved.path.count + 1)) + (type == .typeDirectory ? "/" : "")
        guard ZIPReader.safePath(rel) else { throw LocalizeError("插件文件名不安全。") }
        entries += 1
        guard entries < 60000 else { throw LocalizeError("插件条目数量超过 60000。") }
        if type == .typeRegular {
            total += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard total <= sizeLimit else { throw LocalizeError("插件总大小超过 2 GiB。") }
            if rel.hasPrefix("lib/") && rel.hasSuffix(".jar") { hasJar = true }
        }
    }
    if let traversalError { throw traversalError }
    guard hasJar else { throw LocalizeError("插件缺少 lib 下的 JAR。") }
}

// 扫描专用的轻量描述符读取：只读 JAR 尾部 EOCD、中央目录和描述符条目本身，
// 不逐条目回读本地文件头（mmap 随机访问会把整个 JAR 分页读入，是扫描的主要开销）。
// 逐条目严格校验保留在导出路径；XML 安全检查仍由 DescriptorParser 完成。
enum DescriptorPeek {
    static let descriptorName = Data("META-INF/plugin.xml".utf8)

    static func read(at url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        guard total <= sizeLimit else { throw LocalizeError("ZIP/JAR 超过 2 GiB。") }
        guard total >= 22 else { throw LocalizeError("ZIP/JAR 文件不完整。") }
        let tailLength = Int(min(total, 65557))
        try handle.seek(toOffset: total - UInt64(tailLength))
        guard let tail = try handle.read(upToCount: tailLength), tail.count == tailLength else { throw LocalizeError("ZIP/JAR 文件不完整。") }
        var end: Int?
        for p in stride(from: tail.count - 22, through: 0, by: -1) {
            if try tail.u32(p) == 0x06054b50, Int(try tail.u16(p + 20)) == tail.count - p - 22 { end = p; break }
        }
        guard let end else { throw LocalizeError("找不到 ZIP 中央目录。") }
        let count = Int(try tail.u16(end + 10))
        let centralSize = Int(try tail.u32(end + 12))
        let centralStart = Int(try tail.u32(end + 16))
        guard try tail.u16(end + 4) == 0, try tail.u16(end + 6) == 0,
              try tail.u16(end + 8) == UInt16(count), count != 65535 else { throw LocalizeError("不支持分卷或 ZIP64 文件。") }
        // centralStart/centralSize 是文件内绝对偏移；EOCD 绝对位置 = total - tailLength + end。
        guard centralStart >= 0, centralSize >= 0, centralSize <= 64 * 1024 * 1024,
              centralStart + centralSize == Int(total) - tailLength + end else { throw LocalizeError("不支持分卷或 ZIP64 文件。") }
        try handle.seek(toOffset: UInt64(centralStart))
        guard let central = try handle.read(upToCount: centralSize), central.count == centralSize else { throw LocalizeError("ZIP 中央目录损坏。") }
        var p = 0, seen = 0
        var match: (local: Int, method: UInt16, crc: UInt32, compressed: Int, size: Int)?
        while p < central.count {
            guard p + 46 <= central.count, try central.u32(p) == 0x02014b50 else { throw LocalizeError("ZIP 中央目录损坏。") }
            let flags = try central.u16(p + 8), method = try central.u16(p + 10)
            let crc = try central.u32(p + 16)
            let compressed = Int(try central.u32(p + 20)), size = Int(try central.u32(p + 24))
            let length = Int(try central.u16(p + 28)), extra = Int(try central.u16(p + 30)), comment = Int(try central.u16(p + 32))
            let local = Int(try central.u32(p + 42))
            let nameEnd = p + 46 + length
            guard nameEnd + extra + comment <= central.count else { throw LocalizeError("ZIP 中央目录损坏。") }
            seen += 1
            if central.subdata(in: (p + 46)..<nameEnd) == descriptorName {
                guard flags & 1 == 0, method == 0 || method == 8,
                      compressed != Int(UInt32.max), size != Int(UInt32.max) else { throw LocalizeError("ZIP 含加密或不支持条目。") }
                guard match == nil else { throw LocalizeError("JAR 内含重复描述符。") }
                match = (local, method, crc, compressed, size)
            }
            p = nameEnd + extra + comment
        }
        guard seen == count else { throw LocalizeError("ZIP 中央目录长度不一致。") }
        guard let entry = match else { return nil }
        guard entry.size <= xmlLimit else { throw LocalizeError("JAR 内描述符过大。") }
        // 仅对描述符条目做本地头校验与数据读取。
        guard entry.local >= 0, entry.local + 30 <= Int(total),
              entry.local + 30 + entry.compressed <= centralStart else { throw LocalizeError("ZIP 数据越界。") }
        try handle.seek(toOffset: UInt64(entry.local))
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              try header.u32(0) == 0x04034b50 else { throw LocalizeError("ZIP 本地头与中央目录不一致。") }
        let nameLength = Int(try header.u16(26)), extraLength = Int(try header.u16(28))
        let dataStart = entry.local + 30 + nameLength + extraLength
        guard dataStart >= 0, dataStart + entry.compressed <= centralStart else { throw LocalizeError("ZIP 数据越界。") }
        try handle.seek(toOffset: UInt64(dataStart))
        guard let payload = try handle.read(upToCount: entry.compressed),
              payload.count == entry.compressed else { throw LocalizeError("ZIP 数据越界。") }
        let content: Data
        if entry.method == 8 {
            content = try inflateRaw(payload, expected: entry.size)
        } else {
            guard entry.compressed == entry.size else { throw LocalizeError("未压缩 ZIP 条目大小异常。") }
            content = payload
        }
        guard zipCRC32(content) == entry.crc else { throw LocalizeError("ZIP/JAR CRC 完整性校验失败。") }
        return content
    }
}

private func readDescriptor(_ root: URL) throws -> PluginDescriptor? {
    var descriptors: [Data] = []
    let direct = root.appendingPathComponent("META-INF/plugin.xml")
    if FileManager.default.fileExists(atPath: direct.path) {
        let attrs = try FileManager.default.attributesOfItem(atPath: direct.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= xmlLimit else { throw LocalizeError("描述符过大。") }
        descriptors.append(try Data(contentsOf: direct))
    }
    let lib = root.appendingPathComponent("lib")
    if let e = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        for case let jar as URL in e where jar.pathExtension.lowercased() == "jar" {
            if try jar.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw LocalizeError("语言插件含链接 JAR。") }
            if let xml = try DescriptorPeek.read(at: jar) { descriptors.append(xml) }
        }
    }
    let unique = Array(Set(descriptors))
    guard unique.count <= 1 else { throw LocalizeError("插件内含多个不同主描述符，无法唯一确定。") }
    return try unique.first.flatMap { try DescriptorParser.read($0) }
}

struct LanguagePlugin: Identifiable, Equatable, Sendable {
    var id: String { directory.path }
    let directory: URL
    let app: URL
    let appName: String
    let build: String
    let descriptor: PluginDescriptor

}
struct ScanResult: Sendable {
    let plugins: [LanguagePlugin]
    let notices: [String]
}
struct ExportResult: Sendable {
    let url: URL
    let sha256: String
    let fileCount: Int
    let bytes: UInt64
    // 目标构建超出声明范围并已改写时的 "since – until"；原样导出时为 nil。
    let patchedRange: String?
}

// 读取 IDE 的平台构建号：build.txt → product-info.json → Info.plist。
func readPlatformBuild(at app: URL) throws -> String {
    let fm = FileManager.default
    for path in ["Contents/Resources/build.txt", "Contents/build.txt"] {
        let file = app.appendingPathComponent(path)
        if fm.fileExists(atPath: file.path) {
            let value = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlatformBuild(value) { return value }
        }
    }
    let product = app.appendingPathComponent("Contents/Resources/product-info.json")
    if fm.fileExists(atPath: product.path), let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: product)) as? [String: Any],
       let build = dict["buildNumber"] as? String, isPlatformBuild(build) { return build }
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
    let value = plist?["CFBundleVersion"] as? String ?? ""
    return isPlatformBuild(value) ? value : ""
}

private struct AppScanOutcome: Sendable {
    let plugins: [LanguagePlugin]
    let notices: [String]
}

// 单个 IDE 的扫描负载：不访问 actor 状态，可在并行任务中执行。
private func scanAppBundle(_ app: URL) throws -> AppScanOutcome {
    let fm = FileManager.default
    var notices: [String] = []
    do {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard fm.fileExists(atPath: infoURL.path) else { return AppScanOutcome(plugins: [], notices: []) }
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String, bundle.hasPrefix("com.jetbrains.") else {
            return AppScanOutcome(plugins: [], notices: [])
        }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
        let build = try readPlatformBuild(at: app)
        let folder = app.appendingPathComponent("Contents/plugins")
        guard fm.fileExists(atPath: folder.path) else { return AppScanOutcome(plugins: [], notices: []) }
        let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var packs: [LanguagePlugin] = []
        for child in children.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            do {
                if let descriptor = try readDescriptor(child) {
                    try checkPluginLayout(child)
                    packs.append(LanguagePlugin(directory: child, app: app, appName: safeLabel(name), build: build, descriptor: descriptor))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if child.lastPathComponent.contains("localization") { notices.append("跳过 \(safeLabel(child.path))：\(error.localizedDescription)") } }
        }
        return AppScanOutcome(plugins: packs, notices: notices)
    } catch is CancellationError { throw CancellationError() }
    catch { notices.append("无法读取 \(safeLabel(app.lastPathComponent))：\(error.localizedDescription)") }
    return AppScanOutcome(plugins: [], notices: notices)
}

actor PluginService {
    func detectTarget(at locations: [URL]) throws -> String {
        for app in locations where FileManager.default.fileExists(atPath: app.path) {
            try Task.checkCancellation()
            if let build = try? readPlatformBuild(at: app), !build.isEmpty { return build }
        }
        return ""
    }
    static func build(at app: URL) throws -> String {
        try readPlatformBuild(at: app)
    }

    func scan(roots: [URL], onDiscovery: (@Sendable (LanguagePlugin) async -> Void)? = nil) async throws -> ScanResult {
        let fm = FileManager.default
        var apps = Set<URL>(), notices: [String] = []
        for root in roots {
            try Task.checkCancellation()
            if root.pathExtension.lowercased() == "app" { apps.insert(root.resolvingSymlinksInPath().standardizedFileURL); continue }
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { url, _ in
                notices.append("无法读取 \(safeLabel(url.path))，请检查该目录的读取权限。")
                return true
            }) else { continue }
            while let url = e.nextObject() as? URL {
                try Task.checkCancellation()
                if e.level > 8 { e.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" { apps.insert(url.resolvingSymlinksInPath().standardizedFileURL); e.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { e.skipDescendants(); continue }
            }
        }
        // 并行处理各 IDE（最多 4 个同时），单个结果到达即批量上报该 IDE 的发现事件。
        var packs: [LanguagePlugin] = []
        let sorted = Array(apps.sorted(by: { $0.path < $1.path }))
        if !sorted.isEmpty {
            let outcomes = try await withThrowingTaskGroup(of: AppScanOutcome.self) { group -> [AppScanOutcome] in
                var next = 0
                for _ in 0..<min(4, sorted.count) {
                    let app = sorted[next]; next += 1
                    group.addTask { try scanAppBundle(app) }
                }
                var collected: [AppScanOutcome] = []
                while let finished = try await group.next() {
                    collected.append(finished)
                    if next < sorted.count {
                        let app = sorted[next]; next += 1
                        group.addTask { try scanAppBundle(app) }
                    }
                }
                return collected
            }
            for outcome in outcomes {
                packs.append(contentsOf: outcome.plugins)
                notices.append(contentsOf: outcome.notices)
                if let onDiscovery {
                    for plugin in outcome.plugins { await onDiscovery(plugin) }
                }
            }
        }
        return ScanResult(plugins: packs, notices: Array(Set(notices)).sorted())
    }

    func export(_ plugin: LanguagePlugin, into directory: URL, target: String, allowOutside: Bool) throws -> ExportResult {
        guard target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPlatformBuild(target) else { throw LocalizeError("目标构建号格式无效。") }
        try Task.checkCancellation()
        if plugin.descriptor.compatibility(with: target) == .outside && !allowOutside { throw LocalizeError("目标构建号在插件声明范围外，请明确确认后再导出。") }
        let patch = DescriptorPatch.compute(descriptor: plugin.descriptor, target: target)
        let output = directory.resolvingSymlinksInPath().standardizedFileURL
        let source = plugin.directory.resolvingSymlinksInPath().standardizedFileURL
        guard !output.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              output != source, !output.path.hasPrefix(source.path + "/") else { throw LocalizeError("输出位置不能在应用包或来源插件内部。") }
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let attrs = try fm.attributesOfItem(atPath: output.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw LocalizeError("输出位置必须是可写目录。") }
        let temp = output.appendingPathComponent(".rebased-localize-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let top = plugin.directory.lastPathComponent
        guard ZIPReader.safePath(top), !top.hasPrefix(".") else { throw LocalizeError("插件顶级目录名称不安全。") }
        let before = try inventory(plugin.directory)
        let staged = temp.appendingPathComponent(top, isDirectory: true)
        try fm.copyItem(at: plugin.directory, to: staged)
        let copied = try inventory(staged)
        guard copied == before, try inventory(plugin.directory) == before,
              try readDescriptor(staged) == plugin.descriptor else { throw LocalizeError("复制不完整或来源已发生变化，请重新扫描。") }
        var records = copied
        if let patch {
            try Self.applyPatch(patch, descriptor: plugin.descriptor, staged: staged, workspace: temp)
            records = try inventory(staged)
            guard let rewritten = try readDescriptor(staged),
                  rewritten.id == plugin.descriptor.id, rewritten.version == plugin.descriptor.version,
                  rewritten.locale == plugin.descriptor.locale, rewritten.label == plugin.descriptor.label,
                  rewritten.dependencies == plugin.descriptor.dependencies,
                  rewritten.since == patch.since, rewritten.until == patch.until, rewritten.strictUntil.isEmpty
            else { throw LocalizeError("改写后的描述符校验失败。") }
        }
        for rel in records.keys.sorted() where rel.hasPrefix("lib/") && rel.lowercased().hasSuffix(".jar") {
            let jar = try ZIPReader(url: staged.appendingPathComponent(rel))
            for entry in jar.entries { try jar.consume(entry) { _ in } }
        }
        let archive = temp.appendingPathComponent("plugin.zip")
        try ZIPWriter.write(root: staged, records: records, to: archive)
        let reader = try ZIPReader(url: archive)
        let expected = Set([top + "/"] + records.keys.map { top + "/" + $0 })
        guard Set(reader.entries.map(\.name)) == expected else { throw LocalizeError("ZIP 目录结构校验失败。") }
        for entry in reader.entries {
            let rel = String(entry.name.dropFirst(top.count + 1))
            if rel.isEmpty { try reader.consume(entry) { _ in }; continue }
            guard let record = records[rel], record.directory == entry.directory, record.size == UInt64(entry.size) else { throw LocalizeError("ZIP 文件清单不一致。") }
            var hash = SHA256()
            try reader.consume(entry) { hash.update(data: $0) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard record.directory || digest == record.hash else { throw LocalizeError("ZIP 内容校验失败。") }
        }
        try Task.checkCancellation()
        let name = top + "-" + plugin.descriptor.version.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression).prefix(60) + "-" + UUID().uuidString.prefix(8) + ".zip"
        let destination = output.appendingPathComponent(String(name))
        // link() 是排他发布，目标存在即失败。暂存与目标在同一文件系统。
        let digest = try fileDigest(archive)
        try Task.checkCancellation()
        let published = archive.path.withCString { a in destination.path.withCString { b in Darwin.link(a, b) } }
        guard published == 0 else { throw LocalizeError("无法发布 ZIP（位置不可写或文件已存在）。") }
        return ExportResult(url: destination, sha256: digest.0, fileCount: records.values.filter { !$0.directory }.count, bytes: digest.2,
                            patchedRange: patch.map { ($0.since.isEmpty ? "…" : $0.since) + " – " + ($0.until.isEmpty ? "…" : $0.until) })
    }

    // 改写暂存副本中的描述符：顶级 META-INF/plugin.xml 直接重写；位于 JAR 内时重建该 JAR。
    private static func applyPatch(_ patch: DescriptorPatch, descriptor: PluginDescriptor, staged: URL, workspace: URL) throws {
        let fm = FileManager.default
        let direct = staged.appendingPathComponent("META-INF/plugin.xml")
        if fm.fileExists(atPath: direct.path) {
            let data = try Data(contentsOf: direct)
            if data == descriptor.data { try patch.apply(to: data).write(to: direct) }
        }
        let lib = staged.appendingPathComponent("lib")
        guard let e = fm.enumerator(at: lib, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let jar as URL in e where jar.pathExtension.lowercased() == "jar" {
            try Task.checkCancellation()
            guard try jar.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            let reader = try ZIPReader(url: jar)
            guard let xml = try reader.descriptorData(), xml == descriptor.data else { continue }
            let patched = try patch.apply(to: xml)
            let rebuilt = workspace.appendingPathComponent("patch-\(UUID().uuidString).jar")
            try JARRewriter.write(reader, replacing: "META-INF/plugin.xml", with: patched, to: rebuilt)
            let check = try ZIPReader(url: rebuilt)
            // 除被替换的描述符条目外，其余条目名称、大小与 CRC 必须与原 JAR 完全一致。
            let source = reader.entries
            let rebuiltEntries = check.entries
            guard rebuiltEntries.map(\.name) == source.map(\.name),
                  zip(rebuiltEntries, source).allSatisfy({ $0.name == "META-INF/plugin.xml" || ($0.size == $1.size && $0.crc == $1.crc) }),
                  try check.descriptorData() == patched else { throw LocalizeError("改写后的 JAR 校验失败。") }
            for entry in check.entries { try check.consume(entry) { _ in } }
            try fm.removeItem(at: jar)
            try fm.moveItem(at: rebuilt, to: jar)
        }
    }
}

private enum ZIPWriter {
    static func write(root: URL, records: [String: FileRecord], to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o644]) else { throw LocalizeError("无法创建临时 ZIP。") }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        let top = root.lastPathComponent
        var all = records
        all[""] = FileRecord(size: 0, hash: "", crc: 0, directory: true, permissions: 0o755)
        var central = Data(), offset: UInt64 = 0
        for rel in all.keys.sorted() {
            try Task.checkCancellation()
            let record = all[rel]!
            let name = Data((top + "/" + rel).utf8)
            guard name.count <= 65535, offset < UInt64(UInt32.max), record.size < UInt64(UInt32.max) else { throw LocalizeError("ZIP 超过标准格式限制。") }
            // JAR 已压缩，外层使用 store 避免重复压缩；保持每个 JAR 字节不变。
            var header = Data()
            header.put32(0x04034b50); header.put16(20); header.put16(0x0800); header.put16(0)
            header.put16(0); header.put16(0x0021); header.put32(record.crc)
            header.put32(UInt32(record.size)); header.put32(UInt32(record.size)); header.put16(UInt16(name.count)); header.put16(0); header.append(name)
            try file.write(contentsOf: header)
            if !record.directory {
                let input = try FileHandle(forReadingFrom: root.appendingPathComponent(rel))
                defer { try? input.close() }
                var actual: UInt64 = 0
                while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                    try Task.checkCancellation()
                    actual += UInt64(chunk.count)
                    guard actual <= record.size else { throw LocalizeError("暂存文件已发生变化。") }
                    try file.write(contentsOf: chunk)
                }
                guard actual == record.size else { throw LocalizeError("暂存文件读取不完整。") }
            }
            central.put32(0x02014b50); central.put16(0x0314); central.put16(20); central.put16(0x0800); central.put16(0)
            central.put16(0); central.put16(0x0021); central.put32(record.crc)
            central.put32(UInt32(record.size)); central.put32(UInt32(record.size)); central.put16(UInt16(name.count))
            central.put16(0); central.put16(0); central.put16(0); central.put16(0)
            let mode = UInt32(record.permissions) | (record.directory ? 0o040000 : 0o100000)
            central.put32((mode << 16) | (record.directory ? 0x10 : 0)); central.put32(UInt32(offset)); central.append(name)
            offset += UInt64(header.count) + record.size
        }
        guard offset + UInt64(central.count) <= sizeLimit else { throw LocalizeError("生成 ZIP 超过 2 GiB。") }
        try file.write(contentsOf: central)
        var end = Data()
        end.put32(0x06054b50); end.put16(0); end.put16(0); end.put16(UInt16(all.count)); end.put16(UInt16(all.count))
        end.put32(UInt32(central.count)); end.put32(UInt32(offset)); end.put16(0)
        try file.write(contentsOf: end)
        try file.synchronize()
    }
}

// 重建 JAR 并替换其中单个条目：其余条目按原始压缩字节原样复制（内容不变），仅替换条目重新压缩。
private func zipCRC32(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { raw in
        UInt32(crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
    }
}

// 内存中的 raw inflate，供描述符窥探使用；超出 expected 的输出或异常流均视为损坏。
private func inflateRaw(_ input: Data, expected: Int) throws -> Data {
    guard expected >= 0, expected <= xmlLimit else { throw LocalizeError("ZIP 解压大小与声明不一致。") }
    if input.isEmpty {
        guard expected == 0 else { throw LocalizeError("ZIP 压缩数据损坏。") }
        return Data()
    }
    var stream = z_stream()
    guard rl_inflate_init(&stream) == Z_OK else { throw LocalizeError("无法初始化解压。") }
    defer { inflateEnd(&stream) }
    var output = Data()
    try input.withUnsafeBytes { raw in
        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
        stream.avail_in = uInt(input.count)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let result = buffer.withUnsafeMutableBytes { out in
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(out.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = buffer.count - Int(stream.avail_out)
            if produced > 0 { output.append(contentsOf: buffer.prefix(produced)) }
            guard output.count <= expected else { throw LocalizeError("ZIP 解压大小与声明不一致。") }
            if result == Z_STREAM_END {
                guard stream.avail_in == 0 else { throw LocalizeError("ZIP 压缩数据包含多余内容。") }
                break
            }
            guard result == Z_OK else { throw LocalizeError("ZIP 压缩数据损坏。") }
        }
    }
    guard output.count == expected else { throw LocalizeError("ZIP 解压大小与声明不一致。") }
    return output
}

private func deflateRaw(_ data: Data) throws -> Data {
    var stream = z_stream()
    guard rl_deflate_init(&stream) == Z_OK else { throw LocalizeError("无法初始化压缩。") }
    defer { deflateEnd(&stream) }
    var output = Data()
    try data.withUnsafeBytes { raw in
        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
        stream.avail_in = uInt(data.count)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let result = buffer.withUnsafeMutableBytes { out in
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(out.count)
                return deflate(&stream, Z_FINISH)
            }
            let produced = buffer.count - Int(stream.avail_out)
            if produced > 0 { output.append(contentsOf: buffer.prefix(produced)) }
            if result == Z_STREAM_END { break }
            guard result == Z_OK else { throw LocalizeError("JAR 条目压缩失败。") }
        }
    }
    return output
}

private enum JARRewriter {
    static func write(_ jar: ZIPReader, replacing name: String, with replacement: Data, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o644]) else { throw LocalizeError("无法创建替换 JAR。") }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        var central = Data(), offset: UInt64 = 0, replaced = false
        for entry in jar.entries {
            try Task.checkCancellation()
            let substituting = entry.name == name
            if substituting { replaced = true }
            let payload: Data
            let size: UInt32
            let crc: UInt32
            if substituting {
                payload = entry.method == 8 ? try deflateRaw(replacement) : replacement
                size = UInt32(replacement.count)
                crc = zipCRC32(replacement)
            } else {
                payload = try jar.data.bytes(entry.offset, entry.compressed)
                size = UInt32(entry.size)
                crc = entry.crc
            }
            let nameBytes = Data(entry.name.utf8)
            var header = Data()
            header.put32(0x04034b50); header.put16(20); header.put16(0x0800); header.put16(entry.method)
            header.put16(0); header.put16(0x0021); header.put32(crc)
            header.put32(UInt32(payload.count)); header.put32(size); header.put16(UInt16(nameBytes.count)); header.put16(0)
            header.append(nameBytes)
            try file.write(contentsOf: header)
            try file.write(contentsOf: payload)
            central.put32(0x02014b50); central.put16(0x0314); central.put16(20); central.put16(0x0800); central.put16(entry.method)
            central.put16(0); central.put16(0x0021); central.put32(crc)
            central.put32(UInt32(payload.count)); central.put32(size); central.put16(UInt16(nameBytes.count))
            central.put16(0); central.put16(0); central.put16(0); central.put16(0)
            let mode: UInt32 = entry.directory ? 0o040755 : 0o100644
            central.put32((mode << 16) | (entry.directory ? 0x10 : 0)); central.put32(UInt32(offset)); central.append(nameBytes)
            offset += UInt64(header.count + payload.count)
        }
        guard replaced, offset + UInt64(central.count) <= sizeLimit else { throw LocalizeError("JAR 内找不到待替换条目。") }
        try file.write(contentsOf: central)
        var end = Data()
        end.put32(0x06054b50); end.put16(0); end.put16(0); end.put16(UInt16(jar.entries.count)); end.put16(UInt16(jar.entries.count))
        end.put32(UInt32(central.count)); end.put32(UInt32(offset)); end.put16(0)
        try file.write(contentsOf: end)
        try file.synchronize()
    }
}
