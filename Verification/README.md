# 核心验证

`CoreChecks.swift` 是独立 Swift 检查入口。`create_fixtures.py` 只用于生成隔离的测试 IDE/JAR（仅 Python 标准库），不是应用依赖。应用完全使用原生 Swift。

在一个可写的临时工作目录执行以下命令。第一步生成 `work/swift-fixtures`；Swift 检查会将样本 ZIP 输出到同一临时目录，不修改真实 IDE。

```sh
python3 "/Users/shenyefan/Documents/Rebased Localize/Verification/create_fixtures.py"
xcrun swiftc -parse-as-library -swift-version 5 \
  -import-objc-header "/Users/shenyefan/Documents/Rebased Localize/Rebased Localize/ArchiveBridge.h" \
  "/Users/shenyefan/Documents/Rebased Localize/Rebased Localize/PluginCore.swift" \
  "/Users/shenyefan/Documents/Rebased Localize/Verification/CoreChecks.swift" \
  -lz -module-cache-path work/SwiftModuleCache -o work/core-checks
work/core-checks "$PWD/work/swift-fixtures"
```

覆盖平台构建读取（包括 SNAPSHOT）、语言插件识别、增量发现事件、兼容范围、安全归档读取、目录完整复制、原始描述符保留、输出校验、取消与清理。构建与实际界面另用 Xcode 和原生应用验证。
