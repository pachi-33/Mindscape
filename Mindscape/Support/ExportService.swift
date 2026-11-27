import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case png
    case pdf
    case markdown
    case opml
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return String(localized: "PNG 图片")
        case .pdf: return String(localized: "PDF 文档")
        case .markdown: return String(localized: "Markdown 大纲")
        case .opml: return String(localized: "OPML 大纲")
        case .json: return String(localized: "JSON 数据")
        }
    }

    var detail: String {
        switch self {
        case .png: return String(localized: "高清图片，适合发微信、文档、演示")
        case .pdf: return String(localized: "矢量文档，适合打印和正式分享")
        case .markdown: return String(localized: "层级大纲，可导入笔记 / 大纲工具")
        case .opml: return String(localized: "通用大纲格式，可导入 XMind、OmniOutliner 等")
        case .json: return String(localized: "完整数据结构，适合备份和迁移")
        }
    }

    var symbol: String {
        switch self {
        case .png: return "photo"
        case .pdf: return "doc.richtext"
        case .markdown: return "text.alignleft"
        case .opml: return "list.bullet.rectangle"
        case .json: return "curlybraces"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .opml: return "opml"
        case .json: return "json"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .pdf: return .pdf
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .opml: return UTType(filenameExtension: "opml") ?? .xml
        case .json: return .json
        }
    }

    var supportsScale: Bool { self == .png }
    var supportsSequence: Bool { self == .png || self == .pdf || self == .json }
}

@MainActor
enum ExportService {
    private static var sharingPicker: NSSharingServicePicker?

    /// 弹出保存面板并写入文件，返回是否成功保存。
    static func save(
        map: MindMap,
        layout: LayoutResult? = nil,
        format: ExportFormat,
        scale: CGFloat = 2
    ) -> Bool {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出 \(format.title)")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(safeFileName(map.title)).\(format.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try makeData(map: map, layout: layout, format: format, scale: scale)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func makeData(
        map: MindMap,
        layout: LayoutResult? = nil,
        format: ExportFormat,
        scale: CGFloat = 2
    ) throws -> Data {
        if map.isSequence, !format.supportsSequence {
            throw ExportError.unsupportedSequenceFormat
        }
        switch format {
        case .png:
            let view = try makeExportView(map: map, layout: layout)
            if map.isSequence {
                let width = ceil(view.bounds.width * scale)
                let height = ceil(view.bounds.height * scale)
                // Reject excessive raster allocations before drawing.
                guard width > 0, height > 0, width <= 32_768, height <= 32_768,
                      width * height <= 32_000_000 else {
                    throw ExportError.sequenceImageTooLarge
                }
                return try sequencePNGData(view: view, width: Int(width), height: Int(height))
            }
            return try pngData(view: view, scale: scale)
        case .pdf:
            let view = try makeExportView(map: map, layout: layout)
            return view.dataWithPDF(inside: view.bounds)
        case .markdown:
            return Data(markdown(map: map).utf8)
        case .opml:
            return Data(opml(map: map).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(map)
        }
    }

    /// 生成用于系统分享的临时文件。
    static func temporaryURL(
        map: MindMap,
        layout: LayoutResult? = nil,
        format: ExportFormat,
        scale: CGFloat = 2
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindscapeShare", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let url = directory.appendingPathComponent(
            "\(safeFileName(map.title))-\(stamp).\(format.fileExtension)"
        )
        let data = try makeData(map: map, layout: layout, format: format, scale: scale)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func share(_ url: URL) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker
        picker.show(
            relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
            of: view,
            preferredEdge: .minY
        )
    }

    // MARK: - Rendering

    private static func makeExportView(map: MindMap, layout: LayoutResult?) throws -> NSView {
        let theme = MapTheme.byID(map.themeID)
        if let source = map.sequenceSource {
            let diagram: SequenceDiagram
            do {
                diagram = try SequenceDiagram.parse(source)
            } catch {
                throw ExportError.invalidSequenceSource(error.localizedDescription)
            }
            guard !diagram.participants.isEmpty else {
                throw ExportError.invalidSequenceSource(String(localized: "添加至少一个参与者后才能导出时序图。"))
            }
            return SequenceDiagramCanvas(diagram: diagram, theme: theme)
        }

        let layout = layout ?? LayoutEngine.layout(map)
        let size = CGSize(
            width: max(layout.bounds.width, 420),
            height: max(layout.bounds.height, 320)
        )
        let view = ExportCanvasView(map: map, layout: layout, theme: theme)
        view.frame = CGRect(origin: .zero, size: size)
        return view
    }

    private static func pngData(view: NSView, scale: CGFloat) throws -> Data {
        let pdf = view.dataWithPDF(inside: view.bounds)
        guard let image = NSImage(data: pdf) else {
            throw ExportError.renderFailed
        }

        let width = Int(ceil(view.bounds.width * scale))
        let height = Int(ceil(view.bounds.height * scale))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ExportError.renderFailed
        }
        representation.size = view.bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        let rect = NSRect(origin: .zero, size: view.bounds.size)
        NSColor.clear.setFill()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ExportError.renderFailed
        }
        return data
    }

    private static func sequencePNGData(view: NSView, width: Int, height: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.renderFailed
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / view.bounds.width, y: -CGFloat(height) / view.bounds.height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)

        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError.renderFailed
        }
        return data
    }

    // MARK: - Text formats

    static func markdown(map: MindMap) -> String {
        var lines: [String] = ["# \(map.title)", ""]

        var visited: Set<UUID> = []
        func walk(_ id: UUID, depth: Int) {
            guard visited.insert(id).inserted, let node = map.node(id) else { return }
            let indent = String(repeating: "  ", count: depth)
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = "\(indent)- \(text.isEmpty ? "未命名" : text)"
            lines.append(line)
            let note = node.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                for noteLine in note.split(separator: "\n") {
                    lines.append("\(indent)  > \(noteLine)")
                }
            }
            for child in map.children(of: id) {
                walk(child.id, depth: depth + 1)
            }
        }

        for (index, rootID) in map.rootIDs.enumerated() {
            if index > 0 { lines.append("") }
            walk(rootID, depth: 0)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func opml(map: MindMap) -> String {
        var lines: [String] = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<opml version=\"2.0\">",
            "<head><title>\(escapeXML(map.title))</title></head>",
            "<body>"
        ]

        var visited: Set<UUID> = []
        func walk(_ id: UUID, depth: Int) {
            guard visited.insert(id).inserted, let node = map.node(id) else { return }
            let indent = String(repeating: "  ", count: depth)
            var attributes = "text=\"\(escapeXML(node.text.isEmpty ? "未命名" : node.text))\""
            let note = node.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                attributes += " _note=\"\(escapeXML(note))\""
            }
            let children = map.children(of: id)
            if children.isEmpty {
                lines.append("\(indent)<outline \(attributes)/>")
            } else {
                lines.append("\(indent)<outline \(attributes)>")
                for child in children {
                    walk(child.id, depth: depth + 1)
                }
                lines.append("\(indent)</outline>")
            }
        }

        for rootID in map.rootIDs {
            walk(rootID, depth: 1)
        }
        lines.append("</body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func safeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? String(localized: "未命名导图") : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return base.components(separatedBy: invalid).joined(separator: "-")
    }
}

enum ExportError: LocalizedError {
    case renderFailed
    case unsupportedSequenceFormat
    case invalidSequenceSource(String)
    case sequenceImageTooLarge

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return String(localized: "生成导出文件失败")
        case .unsupportedSequenceFormat:
            return String(localized: "UML 时序图支持 JSON、PNG 和 PDF 导出。")
        case .invalidSequenceSource(let message):
            return message
        case .sequenceImageTooLarge:
            return String(localized: "时序图的 PNG 尺寸过大。请降低清晰度或导出 PDF。")
        }
    }
}

final class ExportCanvasView: NSView {
    private let map: MindMap
    private let layout: LayoutResult
    private let theme: MapTheme

    init(map: MindMap, layout: LayoutResult, theme: MapTheme) {
        self.map = map
        self.layout = layout
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        MapRenderer.drawBackground(theme: theme, in: bounds)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let offsetX = -layout.bounds.minX
        let offsetY = -layout.bounds.minY
        context.saveGState()
        context.translateBy(x: offsetX, y: offsetY)
        MapRenderer.draw(
            map: map,
            layout: layout,
            theme: theme,
            selection: RenderSelection(),
            in: context
        )
        context.restoreGState()
    }
}
