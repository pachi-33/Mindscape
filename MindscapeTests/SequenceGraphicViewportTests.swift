import AppKit
import XCTest
@testable import Mindscape

@MainActor
final class SequenceGraphicViewportTests: XCTestCase {
    private let source = "participant A\nparticipant B\nparticipant C\nparticipant D\n"
        + String(repeating: "A->>B: A row in a long sequence\n", count: 100)

    func testInitialFitAndWideningKeepParticipantCardsVisible() throws {
        let diagram = try SequenceDiagram.parse(source)
        let viewport = SequenceGraphicScrollView(diagram: diagram, theme: MapTheme.byID("paper"),
                                                camera: SequenceGraphicCamera())
        viewport.setFrameSize(CGSize(width: 420, height: 700))
        viewport.layout()
        viewport.setFrameSize(CGSize(width: 670, height: 740))
        viewport.layout()

        let visible = viewport.contentView.bounds
        for participant in diagram.participants {
            let card = try XCTUnwrap(viewport.canvas.bounds(for: .participant(participant.id)))
            XCTAssertTrue(visible.contains(card), "The participant card for \(participant.id) is clipped")
        }
    }

    func testRefitKeepsScrollPositionAfterAnEditAndResize() throws {
        let theme = MapTheme.byID("paper")
        let diagram = try SequenceDiagram.parse(source)
        let viewport = SequenceGraphicScrollView(diagram: diagram, theme: theme, camera: SequenceGraphicCamera())
        viewport.setFrameSize(CGSize(width: 670, height: 740))
        viewport.layout()
        viewport.contentView.scroll(to: CGPoint(x: 0, y: 1_000))
        let originalTop = viewport.contentView.bounds.minY
        XCTAssertGreaterThan(originalTop, 0)

        let edited = try SequenceDiagram.parse(source + "loop Additional frame\nend")
        viewport.update(diagram: edited, theme: theme, reveal: nil)
        viewport.layout()
        XCTAssertEqual(viewport.contentView.bounds.minY, originalTop, accuracy: 1)

        viewport.setFrameSize(CGSize(width: 510, height: 690))
        viewport.layout()
        XCTAssertEqual(viewport.contentView.bounds.minY, originalTop, accuracy: 1)
    }
}
