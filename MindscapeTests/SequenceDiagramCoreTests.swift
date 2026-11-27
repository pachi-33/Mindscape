import XCTest
@testable import Mindscape

final class SequenceDiagramCoreTests: XCTestCase {
    func testBlankSourceAndHeader() throws {
        for source in ["", "\n \t", "\nsequenceDiagram\r\n\t"] {
            let diagram = try SequenceDiagram.parse(source)
            XCTAssertTrue(diagram.participants.isEmpty)
            XCTAssertTrue(diagram.events.isEmpty)
        }
    }

    func testParseOrderedParticipantsAndNestedEvents() throws {
        let source = """
        sequenceDiagram
        participant s0 as 调度器 0
        participant _s1 as Scheduler 1: worker
        participant worker
        loop 槽位
            s0 ->> _s1: 调用: m
            activate _s1
            alt 有任务
                par 本地处理
                    activate _s1
                    _s1->>_s1: 调用本地处理器
                    deactivate _s1
                and 远程处理
                    _s1-)worker: 投递
                    Note over worker, _s1: 远程通道
                end
            else 无任务
                opt 记录状态
                    Note over _s1: 空槽
                end
            end
            _s1-->>s0: 返回
            deactivate _s1
        end
        """

        let diagram = try SequenceDiagram.parse(source)
        XCTAssertEqual(diagram.participants, [
            .init(id: "s0", label: "调度器 0"),
            .init(id: "_s1", label: "Scheduler 1: worker"),
            .init(id: "worker", label: "worker")
        ])
        XCTAssertEqual(diagram.events, [
            .beginBlock(kind: .loop, label: "槽位"),
            .message(from: "s0", to: "_s1", kind: .synchronous, label: "调用: m"),
            .activate(participant: "_s1"),
            .beginBlock(kind: .alt, label: "有任务"),
            .beginBlock(kind: .par, label: "本地处理"),
            .activate(participant: "_s1"),
            .message(from: "_s1", to: "_s1", kind: .synchronous, label: "调用本地处理器"),
            .deactivate(participant: "_s1"),
            .branch(kind: .andBranch, label: "远程处理"),
            .message(from: "_s1", to: "worker", kind: .asynchronous, label: "投递"),
            .note(participants: ["worker", "_s1"], label: "远程通道"),
            .endBlock,
            .branch(kind: .elseBranch, label: "无任务"),
            .beginBlock(kind: .opt, label: "记录状态"),
            .note(participants: ["_s1"], label: "空槽"),
            .endBlock,
            .endBlock,
            .message(from: "_s1", to: "s0", kind: .reply, label: "返回"),
            .deactivate(participant: "_s1"),
            .endBlock
        ])
    }

    func testDiagnosticsUseOneBasedSourceLines() {
        let examples: [(String, Int)] = [
            ("participant A\r\n\r\nA->>B: 消息\r\nparticipant B", 3),
            ("participant A\nparticipant A as 重复", 2),
            ("participant 0A", 1),
            ("participant A as", 1),
            ("participant A\nA->>A:", 2),
            ("participant A\nA=>A: 消息", 2),
            ("participant A\nNote over A,A: 重复", 2),
            ("participant A\nNote over A,B: 未声明", 2),
            ("participant A\nactivate B", 2),
            ("participant A\ndeactivate A", 2),
            ("participant A\nactivate A\nactivate A\ndeactivate A", 2),
            ("participant A\nloop 外层\n\nopt 内层", 4),
            ("participant A\nend", 2),
            ("participant A\nloop\nelse 分支\nend", 3),
            ("participant A\nalt\nelse 甲\nelse 乙\nend", 4),
            ("participant A\npar\nopt\nand 分支\nend\nend", 4),
            ("participant A\nsequenceDiagram", 2)
        ]

        for (source, expectedLine) in examples {
            assertParseError(source, at: expectedLine)
        }
    }

    func testParsingBounds() {
        let participants = (1...25).map { "participant P\($0)" }.joined(separator: "\n")
        assertParseError(participants, at: 25)
        assertParseError("participant A\n" + String(repeating: "A->>A: 重复\n", count: 601), at: 602)
        assertParseError("participant A\n" + String(repeating: "loop\n", count: 17), at: 18)
        assertParseError("participant A\n" + String(repeating: "activate A\n", count: 17), at: 18)
        assertParseError("participant A\nA->>A: " + String(repeating: "字", count: 257), at: 2)
        assertParseError(String(repeating: " ", count: 128 * 1024 + 1), at: 1)
    }

    func testGraphicalEditsKeepLifelineIdentityAndRoundTripLabels() throws {
        var diagram = try SequenceDiagram.parse("")
        let first = try diagram.applying(.addParticipant(label: ""))
        let second = try first.diagram.applying(.addParticipant(label: ""))
        let a = try XCTUnwrap(first.diagram.participants.first?.id)
        let b = try XCTUnwrap(second.diagram.participants.last?.id)
        XCTAssertEqual(first.selection, .participant(a))
        XCTAssertEqual(second.selection, .participant(b))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(second.diagram.participants[0].label, second.diagram.participants[1].label)

        diagram = try second.diagram.applying(.renameParticipant(id: a, label: "代理: 🤝🏽")).diagram
        diagram = try diagram.applying(.insertEvent(.message(from: a, to: b, kind: .asynchronous, label: "发送: {消息}"), at: 0)).diagram
        diagram = try diagram.applying(.insertEvent(.note(participants: [a, b], label: "备注: A ->> B"), at: 1)).diagram
        diagram = try diagram.applying(.insertEvent(.message(from: b, to: b, kind: .synchronous, label: "自调用"), at: 2)).diagram
        diagram = try diagram.applying(.replaceEvent(index: 0, with: .message(from: b, to: a, kind: .reply, label: "返回: {结果}"))).diagram
        let moved = try diagram.applying(.moveEvent(index: 1, to: 3))
        XCTAssertEqual(moved.selection, .event(2))
        diagram = try moved.diagram.applying(.moveParticipant(id: a, to: 2)).diagram

        XCTAssertEqual(diagram.participants.map(\.id), [b, a])
        XCTAssertEqual(diagram.participants.last?.label, "代理: 🤝🏽")
        XCTAssertEqual(diagram.events, [
            .message(from: b, to: a, kind: .reply, label: "返回: {结果}"),
            .message(from: b, to: b, kind: .synchronous, label: "自调用"),
            .note(participants: [a, b], label: "备注: A ->> B")
        ])
        XCTAssertEqual(try SequenceDiagram.parse(diagram.serializedSource), diagram)

        let deleted = try diagram.applying(.delete(.participant(a)))
        XCTAssertNil(deleted.selection)
        XCTAssertEqual(deleted.diagram.participants.map(\.id), [b])
        XCTAssertEqual(deleted.diagram.events, [
            .message(from: b, to: b, kind: .synchronous, label: "自调用"),
            .note(participants: [b], label: "备注: A ->> B")
        ])
    }

    func testGraphicalFragmentCursorCanNestMoveAndDeleteCompleteGroups() throws {
        let initial = try SequenceDiagram.parse("participant A\nA->>A: 外部")
        let outer = try initial.applying(.insertFragment(kind: .alt, label: "->> 最外层", at: 1))
        XCTAssertEqual(outer.selection, .event(1))
        XCTAssertEqual(outer.diagram.containingFragment(at: 2), 1)
        XCTAssertNil(outer.diagram.containingFragment(at: 3))

        let nested = try outer.diagram.applying(.insertFragment(kind: .par, label: "并行", at: 2))
        let branch = try nested.diagram.applying(.insertBranch(in: 2, at: 3, label: "并行分支"))
        XCTAssertEqual(branch.selection, .event(3))
        XCTAssertEqual(branch.diagram.pairedEvent(for: 1), 5)
        XCTAssertEqual(branch.diagram.pairedEvent(for: 4), 2)
        XCTAssertThrowsError(try branch.diagram.applying(.insertBranch(in: 1, at: 3, label: "跨越嵌套")))
        XCTAssertThrowsError(try branch.diagram.applying(.moveEvent(index: 1, to: 4)))
        XCTAssertThrowsError(try branch.diagram.applying(.wrapFragment(kind: .opt, label: "片段交叉", range: 0..<3)))

        let alternative = try branch.diagram.applying(.insertBranch(in: 1, at: 5, label: "另一种情况"))
        XCTAssertThrowsError(try alternative.diagram.applying(.insertBranch(in: 1, at: 6, label: "重复 else")))
        let moved = try alternative.diagram.applying(.moveEvent(index: 6, to: 0))
        XCTAssertEqual(moved.selection, .event(0))
        XCTAssertEqual(moved.diagram.pairedEvent(for: 0), 5)
        XCTAssertEqual(moved.diagram.events.last, .message(from: "A", to: "A", kind: .synchronous, label: "外部"))
        let deleted = try moved.diagram.applying(.delete(.event(5)))
        XCTAssertEqual(deleted.diagram, initial)
    }

    func testGraphicalActivationEditsPreservePairsAcrossResizeAndDelete() throws {
        let initial = try SequenceDiagram.parse("participant A\nparticipant B\nA->>A: 一\nA->>A: 二\nA->>A: 三")
        let inserted = try initial.applying(.insertActivation(participant: "A", at: 0, end: 1))
        XCTAssertEqual(inserted.diagram.pairedEvent(for: 2), 0)
        let moved = try inserted.diagram.applying(.moveEvent(index: 2, to: 4))
        XCTAssertEqual(moved.selection, .event(2))
        XCTAssertEqual(moved.diagram.pairedEvent(for: 2), 4)
        let changed = try moved.diagram.applying(.replaceActivation(index: 2, participant: "B", end: 3))
        XCTAssertEqual(changed.diagram.events[2], .activate(participant: "B"))
        XCTAssertEqual(changed.diagram.events[3], .deactivate(participant: "B"))
        XCTAssertEqual(try changed.diagram.applying(.delete(.event(3))).diagram, initial)

        let neighboring = try inserted.diagram.applying(.insertActivation(participant: "A", at: 3, end: 4))
        XCTAssertEqual(neighboring.diagram.pairedEvent(for: 3), 5)
        XCTAssertThrowsError(try neighboring.diagram.applying(.resizeActivation(index: 0, end: 5)))
        XCTAssertThrowsError(try inserted.diagram.applying(.insertActivation(participant: "A", at: 1, end: 4)))
    }

    private func assertParseError(_ source: String, at expectedLine: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SequenceDiagram.parse(source), file: file, line: line) { error in
            let diagnostic = error as? SequenceDiagram.ParseError
            XCTAssertEqual(diagnostic?.line, expectedLine, file: file, line: line)
            XCTAssertTrue(diagnostic?.localizedDescription.contains(String(expectedLine)) == true, file: file, line: line)
        }
    }
}

@MainActor
final class SequenceDiagramPersistenceTests: XCTestCase {
    func testGraphicalEditorCommitsValidEditsAsSingleUndoSteps() throws {
        let store = try DocumentStore(inMemory: true)
        let map = MapTemplate.sequence.makeMap(themeID: "paper", layout: .mindMap)
        let editor = MapEditor(map: map, store: store)

        let selection = try editor.editSequence(.addParticipant(label: "调度器"))
        guard case .participant(let id) = selection else { return XCTFail("应选中新建生命线") }
        try editor.editSequence(.insertFragment(kind: .loop, label: "槽位", at: 0))
        let fragmentOnly = try editor.sequenceDiagram
        XCTAssertEqual(fragmentOnly.events.count, 2)
        try editor.editSequence(.insertEvent(.message(from: id, to: id, kind: .synchronous, label: "运行"), at: 1))
        let completed = try editor.sequenceDiagram
        XCTAssertEqual(editor.undoCount, 3)
        XCTAssertThrowsError(try editor.editSequence(.insertEvent(.message(from: id, to: "Missing", kind: .reply, label: "无效"), at: 1)))
        XCTAssertEqual(editor.undoCount, 3)
        XCTAssertEqual(try editor.sequenceDiagram, completed)
        editor.undo()
        XCTAssertEqual(try editor.sequenceDiagram, fragmentOnly)
        editor.redo()
        try editor.flushPendingSequenceSave()
        let reopened = MapEditor(map: try XCTUnwrap(store.load(id: map.id)), store: store)
        XCTAssertEqual(try reopened.sequenceDiagram, completed)
    }

    func testEmptySequenceIsDistinctFromLegacyTreeAndCanBeReopened() throws {
        let store = try DocumentStore(inMemory: true)
        let sequence = MapTemplate.sequence.makeMap(themeID: "paper", layout: .mindMap)
        let tree = MapTemplate.blank.makeMap(themeID: "paper", layout: .mindMap)

        let legacyJSON = try JSONEncoder().encode(tree)
        XCTAssertNil((try JSONSerialization.jsonObject(with: legacyJSON) as? [String: Any])?["sequenceSource"])
        let legacyTree = try JSONDecoder().decode(MindMap.self, from: legacyJSON)
        XCTAssertFalse(legacyTree.isSequence)
        XCTAssertEqual(legacyTree.nodes, tree.nodes)

        try store.save(sequence)
        try store.save(legacyTree)
        let blank = try XCTUnwrap(store.load(id: sequence.id))
        XCTAssertTrue(blank.isSequence)
        XCTAssertEqual(blank.sequenceSource, "")
        XCTAssertTrue(blank.nodes.isEmpty)
        XCTAssertTrue(MapEditor(map: blank, store: store).selection.isEmpty)
        XCTAssertEqual(try store.list().first { $0.id == sequence.id }?.isSequence, true)
        XCTAssertEqual(try store.list().first { $0.id == tree.id }?.isSequence, false)
    }

    func testEditorSavesDraftUndoRedoAndSnapshotWithExactSource() throws {
        let store = try DocumentStore(inMemory: true)
        let map = MapTemplate.sequence.makeMap(themeID: "paper", layout: .mindMap)
        let folder = try store.createFolder(name: "时序", parentID: nil)
        try store.save(map, folderID: folder.id)
        let editor = MapEditor(map: map, store: store)
        let draft = "participant A as Cafe\u{0301}\r\nA->>尚未声明: 草稿\r\n "
        let replacement = "participant A as Café\r\nA->>尚未声明: 草稿\r\n "

        XCTAssertThrowsError(try SequenceDiagram.parse(draft))
        XCTAssertNil(editor.addRoot())
        editor.setLayout(.free)
        XCTAssertEqual(editor.map.layout, .mindMap)
        editor.setSequenceSource(draft)
        try editor.flushPendingSequenceSave()
        XCTAssertTrue(try XCTUnwrap(store.load(id: map.id)?.sequenceSource).utf8.elementsEqual(draft.utf8))
        let record = try XCTUnwrap(store.list().first)
        XCTAssertEqual(record.folderID, folder.id)
        XCTAssertTrue(record.preview.contains("尚未声明"))

        XCTAssertTrue(editor.createSnapshot(name: "未完成"))
        let snapshot = try XCTUnwrap(editor.snapshots().first)
        XCTAssertTrue(snapshot.isSequence)
        editor.setSequenceSource(replacement)
        XCTAssertTrue(try XCTUnwrap(editor.map.sequenceSource).utf8.elementsEqual(replacement.utf8))
        editor.undo()
        XCTAssertTrue(try XCTUnwrap(editor.map.sequenceSource).utf8.elementsEqual(draft.utf8))
        editor.redo()
        try editor.flushPendingSequenceSave()
        XCTAssertTrue(try XCTUnwrap(store.load(id: map.id)?.sequenceSource).utf8.elementsEqual(replacement.utf8))

        editor.restore(snapshot: snapshot)
        let reopened = MapEditor(map: try XCTUnwrap(store.load(id: map.id)), store: store)
        XCTAssertTrue(try XCTUnwrap(reopened.map.sequenceSource).utf8.elementsEqual(draft.utf8))
        XCTAssertEqual(reopened.map.title, map.title)
    }

    func testExternalSaveCanReplaceFolderWithoutPendingEditorOverwrite() throws {
        let store = try DocumentStore(inMemory: true)
        var map = MapTemplate.sequence.makeMap(themeID: "paper", layout: .mindMap)
        let folder = try store.createFolder(name: "待整理", parentID: nil)
        try store.save(map, folderID: folder.id)
        let editor = MapEditor(map: map, store: store)
        editor.setSequenceSource("participant Local")
        try editor.flushPendingSequenceSave()
        editor.setSequenceSource("participant Pending")

        map.sequenceSource = "participant External"
        try store.save(map, replaceFolder: true)
        editor.cancelPendingSave()
        try editor.flushPendingSequenceSave()

        XCTAssertEqual(try store.load(id: map.id)?.sequenceSource, "participant External")
        XCTAssertNil(try store.list().first?.folderID)
    }

    func testVersionTwoStoreMigrationRetainsTreeAndSnapshotMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = MapTemplate.blank.makeMap(themeID: "paper", layout: .mindMap)
        let databaseURL: URL
        do {
            let store = try DocumentStore(directory: directory)
            try store.save(tree)
            try store.addSnapshot(tree, name: "旧快照", kind: "manual")
            databaseURL = try XCTUnwrap(store.databaseURL)
        }
        do {
            let fixture = try SQLiteDatabase(path: databaseURL.path)
            try fixture.execute("""
            ALTER TABLE documents DROP COLUMN is_sequence;
            ALTER TABLE snapshots DROP COLUMN is_sequence;
            PRAGMA user_version = 2;
            """)
        }

        let migrated = try DocumentStore(directory: directory)
        let record = try XCTUnwrap(migrated.list().first)
        XCTAssertFalse(record.isSequence)
        XCTAssertEqual(record.nodeCount, 1)
        XCTAssertEqual(record.preview, tree.primaryHeadText)
        XCTAssertNil(try migrated.load(id: tree.id)?.sequenceSource)
        let snapshot = try XCTUnwrap(migrated.snapshots(for: tree.id).first)
        XCTAssertFalse(snapshot.isSequence)
        XCTAssertEqual(try migrated.loadSnapshot(snapshot.id)?.nodes, tree.nodes)
    }
}
