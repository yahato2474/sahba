import AppKit

/// Ctrl wheel: things to do with files and folders, without changing them.
enum Actions {
    static func airDrop(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            HUD.shared.flash(tr("AirDrop مو متاح الحين", "AirDrop isn't available right now", "今はAirDropを使えません"), failed: true)
            return
        }
        service.perform(withItems: urls)
    }

    static func copyPath(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        HUD.shared.flash(urls.count == 1 ? tr("انتسخ المسار", "Path copied", "パスをコピーしました") : tr("انتسخت \(urls.count) مسارات", "\(urls.count) paths copied", "\(urls.count)件のパスをコピーしました"))
    }

    static func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("انقل هنا", "Move Here", "ここに移動")
        panel.message = urls.count == 1
            ? tr("وين تبي تنقل \(urls[0].lastPathComponent)؟", "Where should \(urls[0].lastPathComponent) go?", "\(urls[0].lastPathComponent) をどこに移動しますか？")
            : tr("وين تبي تنقل \(urls.count) ملفات؟", "Where should \(urls.count) files go?", "\(urls.count)個のファイルをどこに移動しますか？")
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var moved = 0
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let dest = Output.unique(in: dir, base: name, ext: url.pathExtension)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                moved += 1
                Log.write("moved \(url.path) -> \(dest.path)")
            } catch {
                Log.write("move failed \(url.path): \(error)")
            }
        }
        HUD.shared.flash(moved == urls.count ? tr("انتقلت إلى \(dir.lastPathComponent)", "Moved to \(dir.lastPathComponent)", "\(dir.lastPathComponent) に移動しました")
                                            : tr("انتقل \(moved) من \(urls.count)", "Moved \(moved) of \(urls.count)", "\(urls.count)個中\(moved)個を移動しました"),
                         failed: moved < urls.count)
    }

    static func terminal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let isDir = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let folder = isDir ? first : first.deletingLastPathComponent()
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func float(_ urls: [URL]) {
        FloatShelf.open(urls, near: NSEvent.mouseLocation)
    }
}

/// Sends files to one of your Tailscale devices with Taildrop (`tailscale file cp`).
/// The device is picked from a menu at the cursor. Taildrop can't send folders, so they go as a .zip.
enum Taildrop {
    static let cli = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Target {
        let name: String
        let online: Bool
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// `tailscale file cp --targets` prints "ip<TAB>name[<TAB>offline; last seen ...]", one device per line.
    static func targets() throws -> [Target] {
        guard let cli else { throw OpError.missingTool("Tailscale") }
        let (status, out, err) = run(cli, ["file", "cp", "--targets"])
        guard status == 0 else { throw OpError.failed(err.isEmpty ? tr("Tailscale ما رد", "Tailscale didn't answer", "Tailscaleが応答しません") : err) }
        return out.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count >= 2 else { return nil }
            return Target(name: cols[1], online: !(cols.count > 2 && cols[2].hasPrefix("offline")))
        }
        .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
    }

    static func send(_ urls: [URL]) {
        let list: [Target]
        do {
            list = try targets()
        } catch {
            HUD.shared.flash((error as? LocalizedError)?.errorDescription ?? "\(error)", failed: true)
            return
        }
        guard !list.isEmpty else {
            HUD.shared.flash(tr("ما في أجهزة لـ Taildrop", "No Taildrop devices", "Taildropの送り先がありません"), failed: true)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: tr("Taildrop إلى…", "Taildrop to…", "Taildropで送る先"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for target in list {
            let title = target.online ? target.name : target.name + tr(" (غير متصل)", " (offline)", "（オフライン）")
            let item = ClosureMenuItem(title: title) { start(urls, to: target.name) }
            item.isEnabled = target.online
            menu.addItem(item)
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func start(_ urls: [URL], to device: String) {
        guard let cli else { return }
        let name = urls.count == 1 ? urls[0].lastPathComponent : tr("\(urls.count) ملفات", "\(urls.count) files", "\(urls.count)個のファイル")
        let id = HUD.shared.begin(tr("إرسال إلى \(device)", "Sending to \(device)", "\(device) に送信中"))
        Log.write("taildrop \(urls.count) -> \(device)")
        DispatchQueue.global(qos: .userInitiated).async {
            // Folders are zipped into a temporary folder first, named like the folder ("Photos.zip").
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sahba-taildrop-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            var paths: [String] = []
            var status: Int32 = 0, err = ""
            for url in urls {
                guard isFolder(url) else { paths.append(url.path); continue }
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let zip = Output.unique(in: tmp, base: url.lastPathComponent, ext: "zip")
                (status, _, err) = run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", url.path, zip.path])
                guard status == 0 else { break }
                paths.append(zip.path)
            }
            if status == 0 {
                (status, _, err) = run(cli, ["file", "cp", "--update-interval=0"] + paths + ["\(device):"])
            }
            DispatchQueue.main.async {
                if status == 0 {
                    HUD.shared.finish(id, title: tr("انرسل: \(name)", "Sent: \(name)", "送信完了: \(name)"), failed: false)
                } else {
                    Log.write("taildrop failed: \(err)")
                    HUD.shared.finish(id, title: tr("ما انرسل: \(err)", "Not sent: \(err)", "送信失敗: \(err)"), failed: true)
                }
            }
        }
    }

    /// Exit status, stdout, and the last line of stderr.
    private static func run(_ exe: String, _ args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return (-1, "", "can't run \(exe)") }
        // Read stderr alongside stdout so a chatty process can't fill one pipe and stall.
        var errData = Data()
        let reader = DispatchQueue(label: "sahba.taildrop.stderr")
        reader.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        reader.sync {}
        let lastErr = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), lastErr)
    }
}

/// A menu item that runs a closure, so a pop-up menu needs no target object.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// A small window that stays on top and holds files, so you can drag them out later.
final class FloatShelf: NSObject {
    private static var shelves: [FloatShelf] = []
    private let panel: NSPanel
    private let shelf: ShelfView

    static func open(_ urls: [URL], near point: NSPoint) {
        shelves.append(FloatShelf(urls, near: point))
    }

    private init(_ urls: [URL], near point: NSPoint) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        shelf = ShelfView(urls: urls)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        shelf.onClose = { [weak self] in self?.close() }
        shelf.onResize = { [weak self] in self?.layout(keepingTopAt: nil) }
        layout(keepingTopAt: NSPoint(x: point.x - ShelfView.width / 2, y: point.y + 40))
        panel.orderFrontRegardless()
    }

    private func layout(keepingTopAt topLeft: NSPoint?) {
        let size = shelf.fittingSize
        let top = topLeft ?? NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let frame = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let glass = WheelController.glass(container.bounds, radius: 18)
        glass.autoresizingMask = [.width, .height]
        shelf.frame = container.bounds
        shelf.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        container.addSubview(shelf)
        panel.contentView = container
        panel.setFrame(frame, display: true)
    }

    private func close() {
        panel.orderOut(nil)
        FloatShelf.shelves.removeAll { $0 === self }
    }
}

final class ShelfView: NSView {
    static let width: CGFloat = 250
    private static let rowHeight: CGFloat = 46, headerHeight: CGFloat = 38, maxRows = 6

    private(set) var urls: [URL]
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?

    init(urls: [URL]) {
        self.urls = urls
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: Self.headerHeight + CGFloat(min(urls.count, Self.maxRows)) * Self.rowHeight + 10)
    }

    override var isFlipped: Bool { true }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: urls.count == 1 ? tr("ملف معلّق", "1 floating file", "フロート中のファイル 1個") : tr("\(urls.count) ملفات معلّقة", "\(urls.count) floating files", "フロート中のファイル \(urls.count)個"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = L10n.arabic ? .right : .left
        title.frame = NSRect(x: 40, y: 11, width: Self.width - 54, height: 16)
        addSubview(title)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: tr("سكّر", "Close", "閉じる"))!,
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: 10, y: 8, width: 22, height: 22)
        addSubview(close)

        for (i, url) in urls.prefix(Self.maxRows).enumerated() {
            let tile = TileView(url: url)
            tile.frame = NSRect(x: 8, y: Self.headerHeight + CGFloat(i) * Self.rowHeight, width: Self.width - 16, height: Self.rowHeight - 4)
            addSubview(tile)
        }
        if urls.count > Self.maxRows {
            title.stringValue += tr(" (يبين أول \(Self.maxRows))", " (showing \(Self.maxRows))", "（先頭\(Self.maxRows)個を表示）")
        }
    }

    @objc private func closeTapped() { onClose?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let new = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let fresh = new.filter { !urls.contains($0) }
        guard !fresh.isEmpty else { return false }
        urls += fresh
        rebuild()
        onResize?()
        return true
    }
}

/// One file in the shelf. Drag it out to copy it anywhere.
final class TileView: NSView, NSDraggingSource {
    let url: URL
    private let icon: NSImage

    init(url: URL) {
        self.url = url
        icon = NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        let image = NSImageView(image: icon)
        image.frame = NSRect(x: 0, y: 0, width: 34, height: 34)
        image.autoresizingMask = [.minXMargin]
        addSubview(image)
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = L10n.arabic ? .right : .left
        addSubview(label)
        self.label = label
        self.image = image
    }

    private var label: NSTextField!
    private var image: NSImageView!

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Icon on the reading side: right in Arabic, left in English.
        let iconX: CGFloat = L10n.arabic ? bounds.width - 40 : 8
        image.frame = NSRect(x: iconX, y: (bounds.height - 32) / 2, width: 32, height: 32)
        label.frame = NSRect(x: L10n.arabic ? 8 : 46, y: (bounds.height - 16) / 2, width: bounds.width - 54, height: 16)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: bounds.width - 40, y: 4, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic, .link]
    }
}
