import AppKit
import PDFKit
import XCTest
@testable import Mindscape

@MainActor
final class SequenceInterchangeTests: XCTestCase {
    private let validSource = """
        participant A as Client
        participant B as Server
        A->>B: Request
        B-->>A: Response
        """

    func testGatewayCreatesBlankSequenceAndPersistsExactDraft() throws {
        let store = try DocumentStore(inMemory: true)
        var changes: [UUID?] = []
        let service = AgentService(store: store) { changes.append($0) }

        let created = try payload(send(service, "POST", "/v1/maps", ["template": "sequence"]), status: 201)
        XCTAssertEqual(created["sequenceSource"] as? String, "")
        XCTAssertEqual((created["rootIds"] as? [String])?.count, 0)
        XCTAssertEqual((created["nodes"] as? [[String: Any]])?.count, 0)
        let id = try XCTUnwrap(created["id"] as? String)
        let documentID = try XCTUnwrap(UUID(uuidString: id))
        let draft = "participant A as Cafe\u{301}\r\nA->>B: 未完成  \r\n"

        let updated = try payload(send(service, "PATCH", "/v1/maps/\(id)", ["sequenceSource": draft]))
        let read = try payload(send(service, "GET", "/v1/maps/\(id)"))
        XCTAssertEqual(Array((updated["sequenceSource"] as? String ?? "").utf8), Array(draft.utf8))
        XCTAssertEqual(Array((read["sequenceSource"] as? String ?? "").utf8), Array(draft.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(store.load(id: documentID)?.sequenceSource).utf8), Array(draft.utf8))
        XCTAssertEqual(try store.list().first?.isSequence, true)
        XCTAssertEqual(changes, [nil, documentID])

        let cleared = try payload(send(service, "PATCH", "/v1/maps/\(id)", ["sequenceSource": ""]))
        XCTAssertEqual(cleared["sequenceSource"] as? String, "")
        XCTAssertEqual(try store.load(id: documentID)?.sequenceSource, "")
    }

    func testGatewayRejectsMixedOperationsBeforeUpdatingAnyFields() throws {
        let store = try DocumentStore(inMemory: true)
        let folder = try store.createFolder(name: "项目", parentID: nil)
        var changes: [UUID?] = []
        var flushes = 0
        let service = AgentService(store: store, beforeReadingSequence: { _ in flushes += 1 }) {
            changes.append($0)
        }
        let sequence = try payload(send(service, "POST", "/v1/maps", [
            "template": "sequence", "title": "时序"
        ]), status: 201)
        let tree = try payload(send(service, "POST", "/v1/maps", ["title": "导图"]), status: 201)
        let sequenceID = try XCTUnwrap(sequence["id"] as? String)
        let treeID = try XCTUnwrap(tree["id"] as? String)
        let existingRoot = try XCTUnwrap((tree["rootIds"] as? [String])?.first)
        let sequencePath = "/v1/maps/\(sequenceID)"

        let rejected: [AgentHTTPResponse] = [
            try send(service, "POST", "/v1/maps", ["template": "sequence", "rootText": "不允许"]),
            try send(service, "POST", sequencePath + "/nodes", ["text": "不允许"]),
            try send(service, "PATCH", sequencePath + "/nodes/\(existingRoot)", ["text": "不允许"]),
            try send(service, "DELETE", sequencePath + "/nodes/\(existingRoot)"),
            try send(service, "POST", sequencePath + "/nodes/\(existingRoot)/move", [:]),
            try send(service, "POST", sequencePath + "/batch", [
                "operations": [["op": "addNode", "text": "不允许"]]
            ]),
            try send(service, "PATCH", sequencePath, [
                "title": "不允许", "layout": "tree", "sequenceSource": validSource
            ]),
            try send(service, "PATCH", "/v1/maps/\(treeID)", [
                "title": "不允许", "sequenceSource": validSource
            ])
        ]
        for response in rejected {
            try assertError(response, status: 400, code: "wrong_document_type")
        }
        try assertError(send(service, "PATCH", sequencePath, ["sequenceSource": NSNull()]),
                        status: 400, code: "bad_request")
        try assertError(send(service, "PATCH", sequencePath, [
            "sequenceSource": validSource, "folderId": UUID().uuidString
        ]), status: 404, code: "not_found")

        XCTAssertEqual(changes, [nil, nil])
        XCTAssertEqual(flushes, 0)
        let documents = try store.list()
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(Set(documents.map(\.title)), ["时序", "导图"])
        let documentID = try XCTUnwrap(UUID(uuidString: sequenceID))
        XCTAssertEqual(try store.load(id: documentID)?.sequenceSource, "")

        _ = try payload(send(service, "PATCH", sequencePath, [
            "folderId": folder.id.uuidString, "sequenceSource": validSource
        ]))
        XCTAssertEqual(try store.list().first(where: { $0.id == documentID })?.folderID, folder.id)
        XCTAssertEqual(try store.load(id: documentID)?.sequenceSource, validSource)
        _ = try payload(send(service, "PATCH", sequencePath, ["folderId": ""]))
        XCTAssertNil(try store.list().first(where: { $0.id == documentID })?.folderID)
        XCTAssertEqual(try store.load(id: documentID)?.sequenceSource, validSource)
    }

    func testGatewayReadAndMetadataUpdateFlushAnOpenSequenceDraft() throws {
        let store = try DocumentStore(inMemory: true)
        let map = MapTemplate.sequence.makeMap(themeID: MapTheme.defaultThemeID, layout: .mindMap)
        try store.save(map)
        let editor = MapEditor(map: map, store: store)
        let service = AgentService(store: store, beforeReadingSequence: { id in
            XCTAssertEqual(id, editor.map.id)
            try editor.flushPendingSequenceSave()
        }) { _ in }
        let path = "/v1/maps/\(map.id.uuidString)"
        editor.setSequenceSource(validSource)
        XCTAssertEqual(try store.load(id: map.id)?.sequenceSource, "")
        let refreshed = try payload(send(service, "GET", path))
        XCTAssertEqual(refreshed["sequenceSource"] as? String, validSource)

        editor.setSequenceSource("participant A\nloop")
        let updated = try payload(send(service, "PATCH", path, ["title": "保存草稿"]))
        XCTAssertEqual(updated["sequenceSource"] as? String, "participant A\nloop")
        XCTAssertEqual(try store.load(id: map.id)?.title, "保存草稿")
    }

    func testGatewayJSONReimportsEmptyValidAndIncompleteSequences() throws {
        let directory = try makeExchangeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(inMemory: true)
        let service = AgentService(store: store) { _ in }

        let created = try payload(send(service, "POST", "/v1/maps", [
            "title": "请求与响应", "template": "sequence"
        ]), status: 201)
        let id = try XCTUnwrap(created["id"] as? String)
        for (index, source) in ["", validSource, "participant A\nA->>X: 草稿\n"].enumerated() {
            _ = try payload(send(service, "PATCH", "/v1/maps/\(id)", ["sequenceSource": source]))
            let path = directory.appendingPathComponent("export-\(index).json").path
            _ = try payload(send(service, "POST", "/v1/maps/\(id)/export", ["format": "json", "path": path]))
            let imported = try payload(send(service, "POST", "/v1/import", ["path": path]), status: 201)
            let summary = try XCTUnwrap(imported["map"] as? [String: Any])
            let importedID = try XCTUnwrap(summary["id"] as? String)
            XCTAssertNotEqual(importedID, id)
            XCTAssertEqual(summary["isSequence"] as? Bool, true)
            XCTAssertEqual(summary["title"] as? String, "请求与响应")
            let importedMap = try payload(send(service, "GET", "/v1/maps/\(importedID)"))
            XCTAssertEqual(importedMap["sequenceSource"] as? String, source)
            XCTAssertEqual((importedMap["nodes"] as? [[String: Any]])?.count, 0)
        }
    }

    func testSharedRendererProducesLabeledPDFAndScaledPNG() throws {
        var map = MapTemplate.sequence.makeMap(themeID: MapTheme.defaultThemeID, layout: .mindMap)
        map.sequenceSource = validSource
        let expectedCanvas = SequenceDiagramCanvas(diagram: try SequenceDiagram.parse(validSource))

        let pdf = try ExportService.makeData(map: map, format: .pdf)
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).size, expectedCanvas.bounds.size)
        let text = try XCTUnwrap(page.string)
        for label in ["Client", "Server", "Request", "Response"] {
            XCTAssertTrue(text.contains(label), text)
        }

        let png = try ExportService.makeData(map: map, format: .png, scale: 2)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, Int(ceil(expectedCanvas.bounds.width * 2)))
        XCTAssertEqual(bitmap.pixelsHigh, Int(ceil(expectedCanvas.bounds.height * 2)))
        let background = bitmap.colorAt(x: 0, y: 0)
        XCTAssertTrue(stride(from: 0, to: bitmap.pixelsHigh, by: 3).contains { y in
            stride(from: 0, to: bitmap.pixelsWide, by: 3).contains { x in bitmap.colorAt(x: x, y: y) != background }
        })
    }

    func testGatewayRejectsGraphicalExportOfDraftAndTreeExportFormats() throws {
        let directory = try makeExchangeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(inMemory: true)
        let service = AgentService(store: store) { _ in }
        let created = try payload(send(service, "POST", "/v1/maps", ["template": "sequence"]), status: 201)
        let id = try XCTUnwrap(created["id"] as? String)
        let exportPath = "/v1/maps/\(id)/export"
        let pdf = directory.appendingPathComponent("diagram.pdf").path
        try assertError(send(service, "POST", exportPath, ["format": "pdf", "path": pdf]),
                        status: 400, code: "invalid_sequence_source")
        _ = try payload(send(service, "PATCH", "/v1/maps/\(id)", [
            "sequenceSource": "participant A\nA->>Missing: Error"
        ]))
        try assertError(send(service, "POST", exportPath, ["format": "pdf", "path": pdf]),
                        status: 400, code: "invalid_sequence_source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf))
        for format in [ExportFormat.markdown, .opml] {
            let path = directory.appendingPathComponent("diagram.\(format.fileExtension)").path
            try assertError(send(service, "POST", exportPath, ["format": format.rawValue, "path": path]),
                            status: 400, code: "wrong_document_type")
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testGatewayRejectsOversizedSequencePNGBeforeWritingAFile() throws {
        let directory = try makeExchangeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DocumentStore(inMemory: true)
        let participants = (0..<24).map { "participant P\($0)" }
        let messages = Array(repeating: "P0->>P0: Process another event", count: 160)
        var map = MapTemplate.sequence.makeMap(themeID: MapTheme.defaultThemeID, layout: .mindMap)
        map.sequenceSource = (participants + messages).joined(separator: "\n")
        try store.save(map)
        let service = AgentService(store: store) { _ in }

        let path = directory.appendingPathComponent("large.png").path
        try assertError(send(service, "POST", "/v1/maps/\(map.id.uuidString)/export", [
            "format": "png", "path": path, "scale": 3
        ]), status: 400, code: "image_too_large")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    private func makeExchangeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/MindscapeSequenceExchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func send(
        _ service: AgentService,
        _ method: String,
        _ path: String,
        _ body: [String: Any]? = nil
    ) throws -> AgentHTTPResponse {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return service.handle(AgentHTTPRequest(method: method, path: path, query: [:], headers: [:], body: data))
    }

    private func payload(
        _ response: AgentHTTPResponse,
        status: Int = 200,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        XCTAssertEqual(response.status, status, String(decoding: response.body, as: UTF8.self), file: file, line: line)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                                     file: file, line: line)
        return try XCTUnwrap(envelope["data"] as? [String: Any], file: file, line: line)
    }

    private func assertError(
        _ response: AgentHTTPResponse,
        status: Int,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(response.status, status, String(decoding: response.body, as: UTF8.self), file: file, line: line)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                                     file: file, line: line)
        XCTAssertEqual((envelope["error"] as? [String: String])?["code"], code, file: file, line: line)
    }
}
