import AppKit
import XCTest
@testable import Mindscape

@MainActor
final class SequenceCanvasInteractionTests: XCTestCase {
    private let source = """
        participant A as Client
        participant B as Worker
        alt primary
        activate A
        A->>B: Request
        deactivate A
        else fallback
        B-)A: Notification
        Note over B: Worker note
        end
        B-->>A: Response
        A->>A: Local work
        """

    func testHitsCardsLifelinesLabelsArrowsFramesNotesAndActivationEndpoints() throws {
        let canvas = SequenceDiagramCanvas(diagram: try SequenceDiagram.parse(source))
        let participant = try XCTUnwrap(canvas.bounds(for: .participant("A")))
        XCTAssertEqual(canvas.selection(at: middle(of: participant)), .participant("A"))
        XCTAssertEqual(canvas.selection(at: CGPoint(x: participant.midX, y: canvas.bounds.maxY - 28)), .participant("A"))

        let frame = try XCTUnwrap(canvas.bounds(for: .event(0)))
        let request = try XCTUnwrap(canvas.bounds(for: .event(2)))
        let divider = try XCTUnwrap(canvas.bounds(for: .event(4)))
        XCTAssertEqual(canvas.selection(at: middle(of: frame)), .event(0))
        XCTAssertEqual(canvas.selection(at: CGPoint(x: frame.minX, y: request.midY)), .event(0))
        XCTAssertEqual(canvas.selection(at: CGPoint(x: divider.midX, y: divider.minY)), .event(4))
        XCTAssertEqual(canvas.selection(at: CGPoint(x: request.midX, y: request.minY + 5)), .event(2))
        XCTAssertEqual(canvas.selection(at: CGPoint(x: request.midX, y: request.maxY - 7)), .event(2))
        XCTAssertNil(canvas.selection(at: CGPoint(x: frame.minX + 30, y: request.maxY + 4)))

        let activationStart = try XCTUnwrap(canvas.bounds(for: .event(1)))
        let activationEnd = try XCTUnwrap(canvas.bounds(for: .event(3)))
        XCTAssertEqual(canvas.selection(at: middle(of: activationStart)), .event(1))
        XCTAssertEqual(canvas.selection(at: middle(of: activationEnd)), .event(3))
        let note = try XCTUnwrap(canvas.bounds(for: .event(6)))
        XCTAssertEqual(canvas.selection(at: middle(of: note)), .event(6))

        let reply = try XCTUnwrap(canvas.bounds(for: .event(8)))
        let selfCall = try XCTUnwrap(canvas.bounds(for: .event(9)))
        XCTAssertEqual(canvas.selection(at: CGPoint(x: reply.midX, y: reply.maxY - 7)), .event(8))
        XCTAssertEqual(canvas.selection(at: CGPoint(x: selfCall.maxX - 8, y: selfCall.maxY - 18)), .event(9))
    }

    func testScrolledMagnifiedClickAndDoubleClickUseDocumentCoordinates() throws {
        let messages = Array(repeating: "A->>B: One event", count: 180)
        let source = (["participant A", "participant B"] + messages).joined(separator: "\n")
        let canvas = SequenceDiagramCanvas(diagram: try SequenceDiagram.parse(source))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 610, height: 360))
        scroll.allowsMagnification = true
        scroll.documentView = canvas
        let window = makeWindow(view: scroll, size: scroll.frame.size)
        scroll.magnification = 1.5

        let bounds = try XCTUnwrap(canvas.bounds(for: .event(168)))
        let point = CGPoint(x: bounds.midX, y: bounds.minY + 5)
        scroll.contentView.scroll(to: CGPoint(x: 120, y: point.y - 140))
        scroll.reflectScrolledClipView(scroll.contentView)
        var selected: [SequenceSelection?] = []
        var edited: [SequenceSelection] = []
        canvas.onSelect = { selected.append($0) }
        canvas.onEdit = { edited.append($0) }
        let location = canvas.convert(point, to: nil)
        XCTAssertTrue(scroll.bounds.contains(scroll.convert(location, from: nil)))

        canvas.mouseDown(with: try mouse(.leftMouseDown, at: location, in: window, count: 2))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: location, in: window, count: 2))
        XCTAssertEqual(selected, [.event(168)])
        XCTAssertEqual(edited, [.event(168)])
    }

    func testLaneToolAndParticipantDragReportTheFinalTarget() throws {
        let canvas = SequenceDiagramCanvas(diagram: try SequenceDiagram.parse("participant A\nparticipant B\nparticipant C"))
        let window = makeWindow(view: canvas, size: canvas.bounds.size)
        let first = try XCTUnwrap(canvas.bounds(for: .participant("A")))
        let second = try XCTUnwrap(canvas.bounds(for: .participant("B")))
        let third = try XCTUnwrap(canvas.bounds(for: .participant("C")))

        var routed: [String] = []
        canvas.onLaneClick = { routed.append($0) }
        for rect in [first, third] {
            let location = canvas.convert(middle(of: rect), to: nil)
            canvas.mouseDown(with: try mouse(.leftMouseDown, at: location, in: window))
            canvas.mouseUp(with: try mouse(.leftMouseUp, at: location, in: window))
        }
        XCTAssertEqual(routed, ["A", "C"])
        canvas.onLaneClick = nil

        var moves: [(String, Int)] = []
        canvas.onMoveParticipant = { moves.append(($0, $1)) }
        let start = canvas.convert(middle(of: first), to: nil)
        let intermediate = canvas.convert(middle(of: second), to: nil)
        let release = canvas.convert(CGPoint(x: third.maxX + 12, y: third.midY), to: nil)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, in: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: intermediate, in: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: release, in: window))
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.0, "A")
        XCTAssertEqual(moves.first?.1, 3)

        canvas.updateDiagram(try SequenceDiagram.parse(source))
        window.setContentSize(canvas.bounds.size)
        let request = try XCTUnwrap(canvas.bounds(for: .event(2)))
        let note = try XCTUnwrap(canvas.bounds(for: .event(6)))
        var eventMoves: [(Int, Int)] = []
        canvas.onMoveEvent = { eventMoves.append(($0, $1)) }
        let requestLabel = canvas.convert(CGPoint(x: request.midX, y: request.minY + 5), to: nil)
        let noteCenter = canvas.convert(middle(of: note), to: nil)
        let lastGap = canvas.convert(CGPoint(x: request.midX, y: canvas.bounds.maxY - 27), to: nil)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: requestLabel, in: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: noteCenter, in: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: lastGap, in: window))
        XCTAssertEqual(eventMoves.count, 1)
        XCTAssertEqual(eventMoves.first?.0, 2)
        XCTAssertEqual(eventMoves.first?.1, 10)
    }

    func testThemeMatchesExportAndSelectionStaysInPreview() throws {
        let diagram = try SequenceDiagram.parse(source)
        let canvas = SequenceDiagramCanvas(diagram: diagram, theme: MapTheme.byID("paper"))
        let header = try XCTUnwrap(canvas.bounds(for: .participant("A")))
        let fill = CGPoint(x: header.minX + 17, y: header.midY)
        let border = CGPoint(x: header.midX, y: header.minY + 1)
        let paper = try raster(canvas)

        let theme = MapTheme.byID("blueprint")
        canvas.setTheme(theme)
        let unselected = try raster(canvas)
        assertColor(try color(in: unselected, at: fill, size: canvas.bounds.size), equals: theme.branchFill)
        XCTAssertNotEqual(try color(in: paper, at: fill, size: canvas.bounds.size).hexString,
                          try color(in: unselected, at: fill, size: canvas.bounds.size).hexString)

        canvas.diagramSelection = .participant("A")
        let selected = try raster(canvas)
        XCTAssertNotEqual(try color(in: selected, at: border, size: canvas.bounds.size).hexString,
                          try color(in: unselected, at: border, size: canvas.bounds.size).hexString)

        let map = MindMap(title: "Theme", themeID: theme.id, sequenceSource: source)
        let exported = try XCTUnwrap(NSBitmapImageRep(data: ExportService.makeData(map: map, format: .png, scale: 1)))
        for sample in [fill, border, CGPoint(x: 7, y: 7), CGPoint(x: 7, y: canvas.bounds.maxY - 7)] {
            assertColor(try color(in: exported, at: sample, size: canvas.bounds.size),
                        equals: try color(in: unselected, at: sample, size: canvas.bounds.size), tolerance: 0.06)
        }
    }

    func testPDFGridKeepsItsThemeTintAndPlacement() throws {
        let scale = 2
        let dots = [CGPoint(x: 13, y: 13), CGPoint(x: 13, y: 39)]
        let backgroundPoint = CGPoint(x: 17, y: 13)
        for themeID in ["paper", "blueprint"] {
            let map = MindMap(title: "Grid", themeID: themeID, sequenceSource: source)
            let pdf = try ExportService.makeData(map: map, format: .pdf)
            let (pdfBitmap, size) = try rasterPDF(pdf, scale: scale)
            let png = try ExportService.makeData(map: map, format: .png, scale: CGFloat(scale))
            let pngBitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            let pdfBackground = try color(in: pdfBitmap, at: backgroundPoint, size: size)
            let pngBackground = try color(in: pngBitmap, at: backgroundPoint, size: size)
            assertColor(pdfBackground, equals: pngBackground)
            for dot in dots {
                let pdfDot = try color(in: pdfBitmap, at: dot, size: size)
                let pngDot = try color(in: pngBitmap, at: dot, size: size)
                XCTAssertNotEqual(pdfDot.hexString, pdfBackground.hexString)
                XCTAssertNotEqual(pngDot.hexString, pngBackground.hexString)
                assertColor(pdfDot, equals: pngDot)
            }
        }
    }

    private func middle(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    private func makeWindow(view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        return window
    }

    private func mouse(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        in window: NSWindow,
        count: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                        clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func raster(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func rasterPDF(_ data: Data, scale: Int) throws -> (NSBitmapImageRep, CGSize) {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let bounds = page.getBoxRect(.mediaBox)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(ceil(bounds.width * CGFloat(scale))),
                                              height: Int(ceil(bounds.height * CGFloat(scale))),
                                              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(page)
        return (NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())), bounds.size)
    }

    private func color(in bitmap: NSBitmapImageRep, at point: CGPoint, size: CGSize) throws -> NSColor {
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / size.width)
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / size.height)
        let raw = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
        // colorAt returns calibrated RGB components even when the bitmap carries another RGB profile.
        let components = [raw.redComponent, raw.greenComponent, raw.blueComponent, raw.alphaComponent]
        let profiled = NSColor(colorSpace: bitmap.colorSpace, components: components, count: components.count)
        return try XCTUnwrap(profiled.usingColorSpace(.sRGB))
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        tolerance: CGFloat = 0.025,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = expected.usingColorSpace(.sRGB) ?? expected
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: tolerance, file: file, line: line)
    }
}
