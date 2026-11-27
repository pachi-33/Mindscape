import AppKit
import Observation
import SwiftUI

struct SequenceReveal: Equatable {
    let id = UUID()
    let selection: SequenceSelection
}

@Observable @MainActor
final class SequenceGraphicCamera {
    private(set) var zoom = 1.0
    @ObservationIgnored fileprivate weak var scrollView: SequenceGraphicScrollView?

    func step(_ factor: CGFloat) {
        guard let scrollView else { return }
        scrollView.isFittingWidth = false
        scrollView.magnification = min(scrollView.maxMagnification, max(scrollView.minMagnification, scrollView.magnification * factor))
        zoom = scrollView.magnification
    }

    func actualSize() {
        scrollView?.isFittingWidth = false
        scrollView?.magnification = 1
        zoom = 1
    }

    func fitWidth() {
        scrollView?.isFittingWidth = true
        scrollView?.fitWidth()
    }

    func center() {
        guard let scrollView, let canvas = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds.size
        let origin = CGPoint(x: max(0, (canvas.bounds.width - visible.width) / 2),
                             y: max(0, (canvas.bounds.height - visible.height) / 2))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    fileprivate func reflect(_ factor: CGFloat) {
        if zoom != factor { zoom = factor }
    }
}

struct SequenceGraphicZoomBar: View {
    let camera: SequenceGraphicCamera

    var body: some View {
        HStack(spacing: 2) {
            icon("minus", title: "缩小") { camera.step(1 / 1.12) }

            Button { camera.actualSize() } label: {
                Text(camera.zoom, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                    .frame(width: 46, height: 22)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("回到 100% 比例")

            icon("plus", title: "放大") { camera.step(1.12) }
            Divider().frame(height: 14).padding(.horizontal, 4)
            icon("arrow.left.and.right", title: "适配宽度") { camera.fitWidth() }
                .accessibilityIdentifier("sequence.zoom.fit")
            icon("dot.squareshape.split.2x2", title: "居中") { camera.center() }
        }
        .padding(.horizontal, 7)
        .frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }

    private func icon(_ symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 25, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct SequenceGraphicCanvas: NSViewRepresentable {
    let diagram: SequenceDiagram
    let theme: MapTheme
    let selection: SequenceSelection?
    let reveal: SequenceReveal?
    let camera: SequenceGraphicCamera
    let onSelect: (SequenceSelection?) -> Void
    let onEdit: (SequenceSelection) -> Void
    let onLaneClick: ((String) -> Void)?
    let onMoveParticipant: (String, Int) -> Void
    let onMoveEvent: (Int, Int) -> Void

    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> SequenceGraphicScrollView {
        let scrollView = SequenceGraphicScrollView(diagram: diagram, theme: theme, camera: camera)
        camera.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: SequenceGraphicScrollView, context: Context) {
        let canvas = scrollView.canvas
        canvas.onSelect = isEnabled ? onSelect : nil
        canvas.onEdit = isEnabled ? onEdit : nil
        canvas.onLaneClick = isEnabled ? onLaneClick : nil
        canvas.onMoveParticipant = isEnabled ? onMoveParticipant : nil
        canvas.onMoveEvent = isEnabled ? onMoveEvent : nil
        canvas.diagramSelection = selection
        scrollView.update(diagram: diagram, theme: theme, reveal: reveal)
    }
}

final class SequenceGraphicScrollView: NSScrollView {
    let canvas: SequenceDiagramCanvas

    private var diagram: SequenceDiagram
    private var theme: MapTheme
    private var previousReveal: SequenceReveal?
    private var fittedWidth: CGSize?
    private var hasPositionedViewport = false
    private weak var camera: SequenceGraphicCamera?
    var isFittingWidth = true {
        didSet { if isFittingWidth { fittedWidth = nil } }
    }

    init(diagram: SequenceDiagram, theme: MapTheme, camera: SequenceGraphicCamera) {
        self.diagram = diagram
        self.theme = theme
        self.camera = camera
        canvas = SequenceDiagramCanvas(diagram: diagram, theme: theme)
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.03
        maxMagnification = 3
        backgroundColor = theme.background
        documentView = canvas
        setAccessibilityIdentifier("sequence.canvas")
    }

    required init?(coder: NSCoder) { nil }

    func update(diagram: SequenceDiagram, theme: MapTheme, reveal: SequenceReveal?) {
        if self.diagram != diagram {
            let origin = contentView.bounds.origin
            self.diagram = diagram
            canvas.updateDiagram(diagram)
            if hasPositionedViewport { restoreScrollOrigin(origin) }
            needsLayout = true
        }
        if self.theme.id != theme.id {
            self.theme = theme
            canvas.setTheme(theme)
            backgroundColor = theme.background
        }
        if let reveal, previousReveal != reveal {
            previousReveal = reveal
            DispatchQueue.main.async { [weak self] in
                self?.reveal(reveal.selection)
            }
        }
    }

    override func layout() {
        let origin = contentView.bounds.origin
        super.layout()
        guard contentView.frame.width > 0, contentView.frame.height > 0 else { return }
        if isFittingWidth { fitWidth() }
        restoreScrollOrigin(hasPositionedViewport ? origin : canvas.frame.origin)
        hasPositionedViewport = true
    }

    override func magnify(with event: NSEvent) {
        isFittingWidth = false
        super.magnify(with: event)
        camera?.reflect(magnification)
    }

    func fitWidth() {
        let viewport = contentView.frame.width
        guard viewport > 0 else { return }
        let widths = CGSize(width: viewport, height: canvas.frame.width)
        guard widths != fittedWidth else { return }
        fittedWidth = widths
        let origin = contentView.bounds.origin
        magnification = min(1, max(minMagnification, viewport / canvas.frame.width))
        restoreScrollOrigin(origin)
        let scale = magnification
        DispatchQueue.main.async { [weak self] in self?.camera?.reflect(scale) }
    }

    private func restoreScrollOrigin(_ origin: CGPoint) {
        // AppKit's magnification anchors to the viewport center. Preserve the top-left
        // document point so the initial fit and subsequent resizing keep their context.
        var bounds = contentView.bounds
        bounds.origin = origin
        let constrained = contentView.constrainBoundsRect(bounds).origin
        guard constrained != contentView.bounds.origin else { return }
        contentView.scroll(to: constrained)
        reflectScrolledClipView(contentView)
    }

    private func reveal(_ selection: SequenceSelection) {
        guard let bounds = canvas.bounds(for: selection) else { return }
        let viewport = contentView.bounds.size
        let rect = CGRect(x: bounds.minX, y: bounds.minY, width: min(bounds.width, viewport.width),
                          height: min(bounds.height, viewport.height * 0.6))
        canvas.scrollToVisible(rect)
    }
}
