import AppKit
import SwiftUI

// 这个单窗口工具只保留实际使用的中文菜单。
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.installMenus() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async { self.installMenus() }
    }
    private func installMenus() {
        let root = NSMenu()
        let application = NSMenu(title: "Rebased Localize")
        let about = NSMenuItem(title: "关于 Rebased Localize", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        application.addItem(about)
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "隐藏 Rebased Localize", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        application.addItem(NSMenuItem(title: "显示主窗口", action: #selector(showWindow), keyEquivalent: "0"))
        application.items.last?.target = self
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "退出 Rebased Localize", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let applicationItem = NSMenuItem(title: "Rebased Localize", action: nil, keyEquivalent: "")
        applicationItem.submenu = application
        root.addItem(applicationItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        root.addItem(editItem)
        NSApp.mainMenu = root
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Rebased Localize",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(string: "提取 JetBrains IDE 语言包，为 Rebased 生成可安装的插件 ZIP。")
        ])
    }
    @objc private func showWindow() {
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "Rebased Localize" }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct FixedWindowConfiguration: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) {}
}

struct DropdownOption: Equatable {
    let id: String
    let title: String
}

// NSPopUpButton 原生左对齐。扫描状态仅放在菜单底部，已发现的选项仍可选择。
struct NativeDropdown: NSViewRepresentable {
    let label: String
    let options: [DropdownOption]
    @Binding var selection: String
    let scanning: Bool
    let enabled: Bool

    final class Coordinator: NSObject {
        var parent: NativeDropdown
        var signature: [String] = []
        init(_ parent: NativeDropdown) { self.parent = parent }
        @objc func choose(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            parent.selection = id
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.alignment = .left
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel(label)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let signature = options.flatMap { [$0.id, $0.title] } + [selection, String(scanning)]
        if signature != context.coordinator.signature {
            context.coordinator.signature = signature
            button.removeAllItems()
            button.menu?.autoenablesItems = false
            if options.isEmpty {
                button.addItem(withTitle: scanning ? "扫描中…" : "未发现可用选项")
                button.lastItem?.isEnabled = false
            } else {
                for option in options {
                    button.addItem(withTitle: option.title)
                    button.lastItem?.representedObject = option.id
                }
                button.selectItem(at: options.firstIndex { $0.id == selection } ?? 0)
                if scanning {
                    button.menu?.addItem(.separator())
                    let status = NSMenuItem(title: "扫描中…", action: nil, keyEquivalent: "")
                    status.isEnabled = false
                    button.menu?.addItem(status)
                }
            }
        }
        button.isEnabled = enabled && (!options.isEmpty || scanning)
        button.toolTip = nil
    }
}
