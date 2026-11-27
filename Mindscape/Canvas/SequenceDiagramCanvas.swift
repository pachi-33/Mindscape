import AppKit

/// The same point-based layout drives the scrollable preview and graphic exports.
final class SequenceDiagramCanvas: NSView {
    private var drawing: SequenceDrawing
    private var explicitTheme: MapTheme?
    private var press: Press?
    private var dropGap: Int?

    var diagramSelection: SequenceSelection? {
        didSet { if oldValue != diagramSelection { needsDisplay = true } }
    }
    var onSelect: ((SequenceSelection?) -> Void)?
    var onEdit: ((SequenceSelection) -> Void)?
    var onLaneClick: ((String) -> Void)?
    var onMoveParticipant: ((String, Int) -> Void)?
    var onMoveEvent: ((Int, Int) -> Void)?

    private struct Press {
        let start: CGPoint
        let selection: SequenceSelection?
        let lane: String?
        let movesParticipant: Bool
        let clicks: Int
        var dragged = false
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var theme: MapTheme {
        if let explicitTheme { return explicitTheme }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return MapTheme.byID(ThemePolicy.defaultID(isDark: dark))
    }

    init(diagram: SequenceDiagram, appearance: NSAppearance? = nil, theme: MapTheme? = nil) {
        drawing = SequenceDrawing(diagram)
        explicitTheme = theme
        super.init(frame: CGRect(origin: .zero, size: drawing.size))
        self.appearance = appearance
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("sequence.preview")
        setAccessibilityLabel(String(localized: "UML 时序图画布"))
        updateAccessibility(diagram)
    }

    required init?(coder: NSCoder) { nil }

    func updateDiagram(_ diagram: SequenceDiagram) {
        press = nil
        dropGap = nil
        drawing = SequenceDrawing(diagram)
        setFrameSize(drawing.size)
        updateAccessibility(diagram)
        needsDisplay = true
    }

    func setTheme(_ theme: MapTheme) {
        guard explicitTheme != theme else { return }
        explicitTheme = theme
        needsDisplay = true
    }

    func selection(at point: CGPoint) -> SequenceSelection? {
        let tolerance = max(4, min(24, 6 / (enclosingScrollView?.magnification ?? 1)))
        return drawing.selection(at: point, tolerance: tolerance)
    }

    func bounds(for selection: SequenceSelection) -> CGRect? {
        drawing.bounds(for: selection)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let selection = selection(at: point)
        let lane = onLaneClick == nil ? nil : drawing.participant(at: point, tolerance: 12)
        press = Press(
            start: event.locationInWindow, selection: selection, lane: lane,
            movesParticipant: drawing.participantHeader(at: point) != nil, clicks: event.clickCount
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var press,
              press.dragged || hypot(event.locationInWindow.x - press.start.x,
                                    event.locationInWindow.y - press.start.y) >= 4 else { return }
        press.dragged = true
        self.press = press
        guard onLaneClick == nil, let selection = press.selection else { return }

        _ = autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let gap = proposedGap(for: selection, movesParticipant: press.movesParticipant, at: point)
        if dropGap != gap {
            dropGap = gap
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        let wasShowingDropGap = dropGap != nil
        dropGap = nil
        if wasShowingDropGap { needsDisplay = true }

        if press.dragged {
            let point = convert(event.locationInWindow, from: nil)
            guard visibleRect.contains(point), onLaneClick == nil, let selection = press.selection,
                  let gap = proposedGap(for: selection, movesParticipant: press.movesParticipant, at: point) else { return }
            onSelect?(selection)
            switch selection {
            case .participant(let id): onMoveParticipant?(id, gap)
            case .event(let index): onMoveEvent?(index, gap)
            }
        } else if let onLaneClick {
            if let lane = press.lane { onLaneClick(lane) }
        } else {
            onSelect?(press.selection)
            if press.clicks == 2, let selection = press.selection {
                onEdit?(selection)
            }
        }
    }

    private func proposedGap(for selection: SequenceSelection, movesParticipant: Bool, at point: CGPoint) -> Int? {
        switch selection {
        case .participant where movesParticipant && onMoveParticipant != nil:
            return drawing.participantGap(at: point.x)
        case let .event(index) where onMoveEvent != nil && drawing.canDrag(event: index):
            return drawing.eventGap(at: point.y)
        default:
            return nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = theme
        MapRenderer.drawBackground(theme: theme, in: bounds)
        Self.drawGrid(theme: theme, in: dirtyRect.intersection(bounds))
        let palette = SequencePalette(theme: theme, height: bounds.height)
        drawing.draw(in: dirtyRect, palette: palette, selection: diagramSelection)
        if let diagramSelection {
            drawing.drawSelection(diagramSelection, in: dirtyRect, accent: theme.accent)
        }
        if let gap = dropGap, let selection = press?.selection {
            drawing.drawDropGap(gap, for: selection, accent: theme.accent)
        }
    }

    private static func drawGrid(theme: MapTheme, in rect: CGRect) {
        guard theme.showsGrid, !rect.isEmpty, let context = NSGraphicsContext.current?.cgContext,
              let patternSpace = CGColorSpace(patternBaseSpace: nil) else { return }

        // A colored tile carries its tint into the exported PDF and follows the canvas transform.
        let tint = Unmanaged.passRetained(theme.grid.withAlphaComponent(0.85).cgColor)
        let cell = CGRect(x: 0, y: 0, width: 26, height: 26)
        var callbacks = CGPatternCallbacks(
            version: 0,
            drawPattern: { info, context in
                guard let info else { return }
                context.setFillColor(Unmanaged<CGColor>.fromOpaque(info).takeUnretainedValue())
                context.fillEllipse(in: CGRect(x: 12.1, y: 12.1, width: 1.8, height: 1.8))
            },
            releaseInfo: { info in
                if let info { Unmanaged<CGColor>.fromOpaque(info).release() }
            }
        )
        guard let pattern = CGPattern(info: tint.toOpaque(), bounds: cell, matrix: context.ctm, xStep: 26, yStep: 26,
                                      tiling: .constantSpacingMinimalDistortion, isColored: true, callbacks: &callbacks) else {
            tint.release()
            return
        }

        context.saveGState()
        context.setFillColorSpace(patternSpace)
        context.setFillPattern(pattern, colorComponents: [1])
        context.fill(rect)
        context.restoreGState()
    }

    private func updateAccessibility(_ diagram: SequenceDiagram) {
        let names = Dictionary(uniqueKeysWithValues: diagram.participants.map { ($0.id, $0.label) })
        let participants = diagram.participants.map(\.label).joined(separator: ", ")
        var description = [String(localized: "参与者：\(participants)")]
        for event in diagram.events {
            let line: String
            switch event {
            case let .message(from, to, kind, label):
                let sender = names[from, default: from]
                let receiver = names[to, default: to]
                switch kind {
                case .synchronous: line = String(localized: "\(sender) 调用 \(receiver)：\(label)")
                case .asynchronous: line = String(localized: "\(sender) 异步发送到 \(receiver)：\(label)")
                case .reply: line = String(localized: "\(sender) 回复 \(receiver)：\(label)")
                }
            case let .note(ids, label):
                let people = ids.map { names[$0, default: $0] }.joined(separator: ", ")
                line = String(localized: "\(people) 的备注：\(label)")
            case let .activate(id):
                line = String(localized: "激活 \(names[id, default: id])")
            case let .deactivate(id):
                line = String(localized: "结束 \(names[id, default: id]) 的激活")
            case let .beginBlock(kind, label): line = "\(kind.rawValue) \(label)"
            case let .branch(kind, label): line = "\(kind.rawValue) \(label)"
            case .endBlock: line = "end"
            }
            description.append(line)
        }
        setAccessibilityValue(description.joined(separator: "\n"))
    }
}

private struct SequencePalette {
    let theme: MapTheme
    let height: CGFloat
    let lifeline: NSColor
    let connector: NSColor
    let activation: NSColor

    init(theme: MapTheme, height: CGFloat) {
        self.theme = theme
        self.height = height
        lifeline = theme.connector.blended(withFraction: 0.32, of: theme.nodeText) ?? theme.connector
        connector = theme.connector.blended(withFraction: 0.74, of: theme.nodeText) ?? theme.nodeText
        activation = theme.branchFill.blended(withFraction: 0.3, of: theme.accent) ?? theme.branchFill
    }

    func background(at y: CGFloat) -> NSColor {
        theme.background.blended(withFraction: max(0, min(1, y / height)), of: theme.backgroundBottom)
            ?? theme.background
    }
}

private struct SequenceDrawing {
    struct Label {
        let source: String
        let rect: CGRect
        let inkBounds: CGRect
        let font: NSFont
        let alignment: NSTextAlignment

        private static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

        init(_ source: String, x: CGFloat, y: CGFloat, width: CGFloat,
             font: NSFont, alignment: NSTextAlignment = .left) {
            self.source = source
            self.font = font
            self.alignment = alignment
            let measured = NSAttributedString(string: source, attributes: Self.attributes(font, alignment))
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: Self.options)
            // Retain the measurement width so drawing uses exactly the same line breaks.
            rect = CGRect(x: x, y: y, width: width, height: source.isEmpty ? 0 : ceil(measured.height) + 1)
            let inkWidth = min(width, ceil(measured.width))
            let inkX = alignment == .center ? rect.midX - inkWidth / 2 : rect.minX
            inkBounds = CGRect(x: inkX, y: y, width: inkWidth, height: rect.height)
        }

        private static func attributes(_ font: NSFont, _ alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            return [.font: font, .paragraphStyle: paragraph]
        }

        func draw(color: NSColor, backing: NSColor? = nil) {
            guard !source.isEmpty else { return }
            if let backing {
                backing.setFill()
                inkBounds.insetBy(dx: -3, dy: -1).fill()
            }
            var attributes = Self.attributes(font, alignment)
            attributes[.foregroundColor] = color
            NSAttributedString(string: source, attributes: attributes).draw(with: rect, options: Self.options)
        }
    }

    struct Lane {
        let id: String
        let x: CGFloat
        let label: Label
    }

    struct Message {
        let index: Int
        let label: Label
        let points: [CGPoint]
        let kind: SequenceDiagram.MessageKind

        var bounds: CGRect {
            // The arrow always runs below its label.
            let start = points[0]
            let end = points[points.count - 1]
            let furthestX = points.map(\.x).max() ?? start.x
            return CGRect(x: min(start.x, end.x), y: start.y,
                          width: max(1, furthestX - min(start.x, end.x)), height: end.y - start.y + 1)
                .insetBy(dx: -8, dy: -6).union(label.inkBounds)
        }

        func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
            label.inkBounds.insetBy(dx: -3, dy: -3).contains(point)
                || SequenceDrawing.isNear(point, path: points, tolerance: tolerance)
        }

        func draw(palette: SequencePalette) {
            label.draw(color: palette.theme.nodeText, backing: palette.background(at: label.rect.midY))
            let isReply = kind == .reply
            let color = palette.connector
            let width: CGFloat = isReply ? 1.4 : 1.7
            SequenceDrawing.stroke(points, color: color, width: width, dash: isReply ? [5, 4] : [])

            let end = points[points.count - 1]
            let tail = points[points.count - 2]
            let direction: CGFloat = end.x > tail.x ? 1 : -1
            let base = end.x - direction * 9
            let tip = [CGPoint(x: base, y: end.y - 4), end, CGPoint(x: base, y: end.y + 4)]
            if kind == .synchronous {
                let arrowhead = SequenceDrawing.path(tip)
                arrowhead.close()
                color.setFill()
                arrowhead.fill()
            } else {
                SequenceDrawing.stroke(tip, color: color, width: width)
            }
        }
    }

    struct Note {
        let index: Int
        let bounds: CGRect
        let label: Label

        func draw(palette: SequencePalette) {
            let fold: CGFloat = 10
            let topFold = CGPoint(x: bounds.maxX - fold, y: bounds.minY)
            let sideFold = CGPoint(x: bounds.maxX, y: bounds.minY + fold)
            let outline = SequenceDrawing.path([
                CGPoint(x: bounds.minX, y: bounds.minY), topFold, sideFold,
                CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)
            ])
            outline.close()
            palette.theme.nodeFill.setFill()
            palette.lifeline.setStroke()
            outline.fill()
            outline.stroke()
            SequenceDrawing.stroke([topFold, CGPoint(x: topFold.x, y: sideFold.y), sideFold], color: palette.lifeline)
            label.draw(color: palette.theme.nodeText)
        }
    }

    struct Fragment {
        struct Branch {
            let index: Int
            let y: CGFloat
            let condition: Label
        }

        let index: Int
        let x: CGFloat
        let width: CGFloat
        let top: CGFloat
        var bottom: CGFloat
        let kind: Label
        let condition: Label?
        var branches: [Branch] = []

        var bounds: CGRect { CGRect(x: x, y: top, width: width, height: bottom - top) }

        var tabBounds: CGRect {
            CGRect(x: x, y: top, width: kind.rect.maxX + 7 - x, height: kind.rect.maxY + 5 - top)
        }

        var headerBounds: CGRect {
            guard let condition else { return tabBounds }
            return tabBounds.union(condition.inkBounds)
        }

        func branchBounds(_ branch: Branch) -> CGRect {
            CGRect(x: x, y: branch.y, width: width, height: branch.condition.rect.maxY - branch.y)
        }

        func containsBorder(_ point: CGPoint, tolerance: CGFloat) -> Bool {
            bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !bounds.insetBy(dx: tolerance, dy: tolerance).contains(point)
        }

        func draw(palette: SequencePalette) {
            palette.lifeline.setStroke()
            NSBezierPath(rect: bounds).stroke()

            let tabBottom = tabBounds.maxY
            let tabRight = tabBounds.maxX
            let tab = SequenceDrawing.path([
                CGPoint(x: x, y: top), CGPoint(x: tabRight, y: top),
                CGPoint(x: tabRight, y: tabBottom - 6), CGPoint(x: tabRight - 6, y: tabBottom),
                CGPoint(x: x, y: tabBottom)
            ])
            tab.close()
            palette.theme.branchFill.setFill()
            tab.fill()
            tab.stroke()
            kind.draw(color: palette.theme.branchText)
            if let condition {
                condition.draw(color: palette.theme.nodeText, backing: palette.background(at: condition.rect.midY))
            }

            for branch in branches {
                SequenceDrawing.stroke([CGPoint(x: x, y: branch.y), CGPoint(x: x + width, y: branch.y)],
                                       color: palette.lifeline, dash: [5, 4])
                branch.condition.draw(color: palette.theme.nodeText,
                                      backing: palette.background(at: branch.condition.rect.midY))
            }
        }
    }

    private struct Activation {
        let beginIndex: Int
        var endIndex: Int? = nil
        let x: CGFloat
        let start: CGFloat
        var end: CGFloat

        var bounds: CGRect { CGRect(x: x - 4.5, y: start, width: 9, height: end - start) }

        func marker(at y: CGFloat) -> CGRect {
            CGRect(x: bounds.minX - 2, y: y - 4, width: bounds.width + 4, height: 8)
        }
    }

    let size: CGSize
    private let lanes: [Lane]
    private let headerHeight: CGFloat
    private let lifelineEnd: CGFloat
    private let messages: [Message]
    private let notes: [Note]
    private let fragments: [Fragment]
    private let activations: [Activation]
    private let eventRows: [CGFloat]
    private let movableEvents: Set<Int>

    init(_ diagram: SequenceDiagram) {
        let top: CGFloat = 24
        let pitch: CGFloat = 228
        let headerWidth: CGFloat = 154
        let firstX = 112 + CGFloat(Self.maxFragmentDepth(diagram)) * 11
        let lastX = firstX + CGFloat(max(0, diagram.participants.count - 1)) * pitch
        let width = lastX + firstX + 101

        let participantFont = NodeMeasurer.font(level: 1)
        let bodyFont = NodeMeasurer.font(level: 2)
        let operatorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let lanes = diagram.participants.enumerated().map { index, participant in
            let x = firstX + CGFloat(index) * pitch
            return Lane(id: participant.id, x: x,
                        label: Label(participant.label, x: x - (headerWidth - 20) / 2,
                                     y: top + 10, width: headerWidth - 20,
                                     font: participantFont, alignment: .center))
        }
        let headerHeight = max(40, (lanes.map { $0.label.rect.height }.max() ?? 0) + 20)
        let laneX = Dictionary(uniqueKeysWithValues: zip(diagram.participants.map(\.id), lanes.map(\.x)))
        var y = top + headerHeight + 19
        var messages: [Message] = []
        var notes: [Note] = []
        var fragments: [Fragment] = []
        var openFragments: [Int] = []
        var activations: [Activation] = []
        var active: [String: [Int]] = [:]
        var eventRows: [CGFloat] = []
        var movableEvents: Set<Int> = []

        func endpoint(_ participant: String, comesFromRight: Bool) -> CGFloat {
            if let index = active[participant]?.last {
                return activations[index].x + (comesFromRight ? 4.5 : -4.5)
            }
            return laneX[participant, default: 0]
        }

        for (index, event) in diagram.events.enumerated() {
            eventRows.append(y)
            switch event {
            case let .message(from, to, kind, source):
                movableEvents.insert(index)
                let leftToRight = laneX[from, default: 0] < laneX[to, default: 0]
                let startX = endpoint(from, comesFromRight: leftToRight || from == to)
                let endX = endpoint(to, comesFromRight: !leftToRight)

                if from == to {
                    let loopRight = laneX[from, default: 0] + 184
                    let labelX = startX + 12
                    let label = Label(source, x: labelX, y: y, width: loopRight - labelX,
                                      font: bodyFont)
                    let arrowY = label.rect.maxY + 8
                    let returnY = arrowY + 22
                    messages.append(Message(index: index, label: label, points: [
                        CGPoint(x: startX, y: arrowY), CGPoint(x: loopRight, y: arrowY),
                        CGPoint(x: loopRight, y: returnY), CGPoint(x: endX, y: returnY)
                    ], kind: kind))
                    y = returnY + 20
                } else {
                    let labelWidth = min(540, abs(endX - startX) - 24)
                    let label = Label(source, x: (startX + endX - labelWidth) / 2, y: y, width: labelWidth,
                                      font: bodyFont, alignment: .center)
                    let arrowY = label.rect.maxY + 8
                    messages.append(Message(index: index, label: label, points: [
                        CGPoint(x: startX, y: arrowY), CGPoint(x: endX, y: arrowY)
                    ], kind: kind))
                    y = arrowY + 20
                }
            case let .note(participants, source):
                movableEvents.insert(index)
                let positions = participants.compactMap { laneX[$0] }
                guard let left = positions.min(), let right = positions.max() else { continue }
                let boxWidth = right - left + 166
                let textWidth = min(620, boxWidth - 28)
                let center = (left + right) / 2
                let label = Label(source, x: center - textWidth / 2, y: y + 9, width: textWidth,
                                  font: bodyFont, alignment: .center)
                let box = CGRect(x: center - boxWidth / 2, y: y, width: boxWidth, height: label.rect.height + 18)
                notes.append(Note(index: index, bounds: box, label: label))
                y = box.maxY + 17
            case let .activate(id):
                movableEvents.insert(index)
                let x = laneX[id, default: 0] + CGFloat(active[id, default: []].count) * 3
                active[id, default: []].append(activations.count)
                activations.append(Activation(beginIndex: index, x: x, start: y, end: y))
                y += 12
            case let .deactivate(id):
                movableEvents.insert(index)
                if let index = active[id]?.popLast() {
                    activations[index].end = y
                    activations[index].endIndex = eventRows.count - 1
                }
                y += 12
            case let .beginBlock(kind, label):
                movableEvents.insert(index)
                let x = 20 + CGFloat(openFragments.count) * 11
                let fragmentWidth = width - 2 * x
                let kindLabel = Label(kind.rawValue, x: x + 7, y: y + 4, width: 34, font: operatorFont)
                let condition = label.isEmpty ? nil : Label("[\(label)]", x: x + 57, y: y + 5,
                                                           width: min(540, fragmentWidth - 71), font: bodyFont)
                openFragments.append(fragments.count)
                fragments.append(Fragment(index: index, x: x, width: fragmentWidth, top: y, bottom: y,
                                          kind: kindLabel, condition: condition))
                y = max(kindLabel.rect.maxY + 5, condition?.rect.maxY ?? y) + 13
            case let .branch(kind, label):
                guard let index = openFragments.last else { continue }
                movableEvents.insert(eventRows.count - 1)
                let text = label.isEmpty ? kind.rawValue : "\(kind.rawValue) [\(label)]"
                let branch = Label(text, x: fragments[index].x + 11, y: y + 6,
                                   width: min(540, fragments[index].width - 23), font: bodyFont)
                fragments[index].branches.append(Fragment.Branch(index: eventRows.count - 1, y: y, condition: branch))
                y = branch.rect.maxY + 12
            case .endBlock:
                if let index = openFragments.popLast() {
                    fragments[index].bottom = y
                }
                y += 14
            }
        }

        size = CGSize(width: ceil(width), height: ceil(y + 27))
        self.lanes = lanes
        self.headerHeight = headerHeight
        lifelineEnd = y + 4
        self.messages = messages
        self.notes = notes
        self.fragments = fragments
        self.activations = activations
        self.eventRows = eventRows + [y]
        self.movableEvents = movableEvents
    }

    private func header(for lane: Lane) -> CGRect {
        CGRect(x: lane.x - 77, y: 24, width: 154, height: headerHeight)
    }

    func participantHeader(at point: CGPoint) -> String? {
        lanes.first { header(for: $0).contains(point) }?.id
    }

    func participant(at point: CGPoint, tolerance: CGFloat) -> String? {
        if let id = participantHeader(at: point) { return id }
        guard (24 + headerHeight...lifelineEnd).contains(point.y) else { return nil }
        return lanes.first { abs($0.x - point.x) <= tolerance }?.id
    }

    func selection(at point: CGPoint, tolerance: CGFloat) -> SequenceSelection? {
        if let note = notes.last(where: { $0.bounds.contains(point) }) {
            return .event(note.index)
        }
        if let message = messages.last(where: { $0.contains(point, tolerance: tolerance) }) {
            return .event(message.index)
        }
        if let activation = activations.last(where: {
            $0.bounds.insetBy(dx: -tolerance / 2, dy: -4).contains(point)
        }) {
            if let end = activation.endIndex, activation.marker(at: activation.end).contains(point) {
                return .event(end)
            }
            return .event(activation.beginIndex)
        }
        for fragment in fragments.reversed() {
            if let branch = fragment.branches.last(where: {
                let withinDivider = point.x >= fragment.bounds.minX && point.x <= fragment.bounds.maxX
                    && abs(point.y - $0.y) <= tolerance
                return withinDivider || $0.condition.inkBounds.insetBy(dx: -3, dy: -3).contains(point)
            }) {
                return .event(branch.index)
            }
            if fragment.headerBounds.insetBy(dx: -3, dy: -3).contains(point)
                || fragment.containsBorder(point, tolerance: tolerance) {
                return .event(fragment.index)
            }
        }
        return participant(at: point, tolerance: tolerance).map(SequenceSelection.participant)
    }

    func bounds(for selection: SequenceSelection) -> CGRect? {
        switch selection {
        case .participant(let id):
            return lanes.first(where: { $0.id == id }).map(header(for:))
        case .event(let index):
            if let message = messages.first(where: { $0.index == index }) { return message.bounds }
            if let note = notes.first(where: { $0.index == index }) { return note.bounds }
            for activation in activations {
                if activation.beginIndex == index { return activation.marker(at: activation.start) }
                if activation.endIndex == index { return activation.marker(at: activation.end) }
            }
            for fragment in fragments {
                if fragment.index == index { return fragment.headerBounds }
                if let branch = fragment.branches.first(where: { $0.index == index }) {
                    return fragment.branchBounds(branch)
                }
            }
            return nil
        }
    }

    func canDrag(event index: Int) -> Bool { movableEvents.contains(index) }

    func participantGap(at x: CGFloat) -> Int {
        lanes.firstIndex { x < $0.x } ?? lanes.count
    }

    func eventGap(at y: CGFloat) -> Int {
        eventRows.indices.min { abs(eventRows[$0] - y) < abs(eventRows[$1] - y) } ?? 0
    }

    func draw(in dirty: CGRect, palette: SequencePalette, selection: SequenceSelection?) {
        for lane in lanes {
            let header = header(for: lane)
            if (dirty.minX - 1...dirty.maxX + 1).contains(lane.x), dirty.maxY >= header.maxY {
                let selected = selection == .participant(lane.id)
                Self.stroke([CGPoint(x: lane.x, y: header.maxY), CGPoint(x: lane.x, y: lifelineEnd)],
                            color: selected ? palette.theme.accent : palette.lifeline,
                            width: selected ? 2 : 1, dash: [5, 5])
            }
            guard header.insetBy(dx: -1, dy: -1).intersects(dirty) else { continue }
            let box = NSBezierPath(roundedRect: header, xRadius: 12, yRadius: 12)
            palette.theme.branchFill.setFill()
            palette.theme.border.setStroke()
            box.fill()
            box.stroke()
            lane.label.draw(color: palette.theme.branchText)
        }

        for fragment in fragments where fragment.bounds.insetBy(dx: -1, dy: -1).intersects(dirty) {
            fragment.draw(palette: palette)
        }
        for activation in activations where activation.bounds.intersects(dirty) {
            palette.activation.setFill()
            activation.bounds.fill()
            palette.lifeline.setStroke()
            NSBezierPath(rect: activation.bounds).stroke()
        }
        for message in messages where message.bounds.intersects(dirty) {
            message.draw(palette: palette)
        }
        for note in notes where note.bounds.insetBy(dx: -1, dy: -1).intersects(dirty) {
            note.draw(palette: palette)
        }
    }

    func drawSelection(_ selection: SequenceSelection, in dirty: CGRect, accent: NSColor) {
        guard var outline = bounds(for: selection) else { return }
        var radius: CGFloat = 5
        if case .participant = selection {
            radius = 11
            outline = outline.insetBy(dx: 1, dy: 1)
        } else if case .event(let index) = selection {
            if let fragment = fragments.first(where: { $0.index == index }) {
                outline = fragment.bounds
                radius = 0
            } else {
                outline = outline.insetBy(dx: -3, dy: -3)
            }
        }
        guard outline.insetBy(dx: -2, dy: -2).intersects(dirty) else { return }
        let ring = NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius)
        ring.lineWidth = 2
        accent.setStroke()
        ring.stroke()
    }

    func drawDropGap(_ gap: Int, for selection: SequenceSelection, accent: NSColor) {
        switch selection {
        case .participant:
            guard let first = lanes.first, let last = lanes.last else { return }
            let x: CGFloat
            if gap == 0 {
                x = header(for: first).minX - 18
            } else if gap == lanes.count {
                x = header(for: last).maxX + 18
            } else {
                x = (lanes[gap - 1].x + lanes[gap].x) / 2
            }
            Self.stroke([CGPoint(x: x, y: 19), CGPoint(x: x, y: 32 + headerHeight)],
                        color: accent, width: 2.5)
        case .event:
            let y = eventRows[gap] - 3
            Self.stroke([CGPoint(x: 16, y: y), CGPoint(x: size.width - 16, y: y)],
                        color: accent, width: 2.5)
        }
    }

    private static func isNear(_ point: CGPoint, path: [CGPoint], tolerance: CGFloat) -> Bool {
        for (a, b) in zip(path, path.dropFirst()) {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            if hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) <= tolerance { return true }
        }
        return false
    }

    private static func maxFragmentDepth(_ diagram: SequenceDiagram) -> Int {
        var height = 0
        var current = 0
        for event in diagram.events {
            switch event {
            case .beginBlock:
                current += 1
                height = max(current, height)
            case .endBlock: current -= 1
            default: break
            }
        }
        return height
    }

    private static func path(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        return path
    }

    private static func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat = 1, dash: [CGFloat] = []) {
        let path = Self.path(points)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if !dash.isEmpty {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        color.setStroke()
        path.stroke()
    }
}
