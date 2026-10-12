# Rebased Localize

原生 macOS SwiftUI 工具：从本机已安装的 JetBrains IDE 中提取内置语言包，为 Rebased 生成可直接安装的插件 ZIP。

## 使用方法

1. 在 Xcode 中打开 `Rebased Localize.xcodeproj`，点击运行（最低 macOS 14）。
2. 启动后自动扫描 `/Applications`、`~/Applications`、JetBrains Toolbox 与 Launch Services 注册的 IDE，发现语言包即更新界面，扫描中可切换语言和来源。
3. 默认选中中文（如存在），并自动读取 `/Applications/Rebased.app` 的真实平台构建号。
4. 目标构建超出声明范围时，导出前会弹出确认；确认后导出并改写构建范围。
5. 导出结果默认保存在 `~/Downloads/Rebased Localize`（可更改），每次生成独立 ZIP 并给出 SHA-256。
6. 在目标 IDE 中 Settings → Plugins → 齿轮菜单 → Install Plugin from Disk 选择导出的 ZIP，按提示重启。

## 已知限制

- 构建范围匹配不能保证产品依赖与运行兼容性，最终由目标 IDE 安装时检查。
