import SwiftUI
import XCTest
@testable import Mindscape

@MainActor
final class SequenceInspectorBindingTests: XCTestCase {
    func testRetainedFragmentFieldsStayReadableAfterLeavingInspector() {
        var draft = SequenceDraft(tool: .fragment, target: .event(4), label: "nested condition", block: .opt)
        let state = DraftState(draft)
        let form = draft.bound(to: state.binding)
        let textField = form.label
        let fragmentPicker = form.block

        state.draft = nil

        XCTAssertEqual(textField.wrappedValue, "nested condition")
        XCTAssertEqual(fragmentPicker.wrappedValue, .opt)
        textField.wrappedValue = "late field update"
        fragmentPicker.wrappedValue = .par
        XCTAssertNil(state.draft)

        draft.session = UUID()
        draft.label = "another condition"
        draft.block = .alt
        state.draft = draft
        textField.wrappedValue = "late field update"
        fragmentPicker.wrappedValue = .loop
        XCTAssertEqual(state.draft?.label, "another condition")
        XCTAssertEqual(state.draft?.block, .alt)
    }

    func testReopeningSameMessageRejectsOldFieldWritesAndAcceptsCurrentOnes() {
        let original = SequenceDraft(tool: .message, target: .event(2), label: "request", from: "A", to: "B")
        let state = DraftState(original)
        let closedForm = original.bound(to: state.binding)
        let oldLabel = closedForm.label
        let oldSender = closedForm.from

        let reopened = SequenceDraft(tool: .message, target: .event(2), label: "request", from: "A", to: "B")
        state.draft = reopened
        let activeForm = reopened.bound(to: state.binding)
        activeForm.label.wrappedValue = "new request"
        activeForm.from.wrappedValue = "C"

        oldLabel.wrappedValue = "stale request"
        oldSender.wrappedValue = "D"
        XCTAssertEqual(state.draft?.session, reopened.session)
        XCTAssertEqual(state.draft?.label, "new request")
        XCTAssertEqual(state.draft?.from, "C")
        XCTAssertEqual(activeForm.label.wrappedValue, "new request")
        XCTAssertEqual(activeForm.from.wrappedValue, "C")
    }

    @MainActor
    private final class DraftState {
        var draft: SequenceDraft?

        init(_ draft: SequenceDraft) {
            self.draft = draft
        }

        var binding: Binding<SequenceDraft?> {
            Binding(get: { self.draft }, set: { self.draft = $0 })
        }
    }
}
