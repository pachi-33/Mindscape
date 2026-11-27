import Foundation

struct SequenceDiagram: Equatable, Sendable {
    struct Participant: Equatable, Sendable {
        let id: String
        let label: String
    }

    enum MessageKind: String, CaseIterable, Sendable {
        case reply = "-->>"
        case synchronous = "->>"
        case asynchronous = "-)"
    }

    enum BlockKind: String, Sendable {
        case loop, opt, alt, par
    }

    enum BranchKind: String, Sendable {
        case elseBranch = "else"
        case andBranch = "and"
    }

    enum Event: Equatable, Sendable {
        case message(from: String, to: String, kind: MessageKind, label: String)
        case note(participants: [String], label: String)
        case activate(participant: String)
        case deactivate(participant: String)
        case beginBlock(kind: BlockKind, label: String)
        case branch(kind: BranchKind, label: String)
        case endBlock
    }

    struct ParseError: LocalizedError, Equatable, Sendable {
        let line: Int
        let message: String

        var errorDescription: String? { String(localized: "第 \(line) 行：\(message)") }
    }

    let participants: [Participant]
    let events: [Event]

    static func parse(_ source: String) throws -> SequenceDiagram {
        guard source.utf8.count <= 128 * 1024 else {
            throw ParseError(line: 1, message: String(localized: "源码最多为 128 KB。"))
        }
        var parser = Parser()
        for (offset, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            try parser.read(line, at: offset + 1)
        }
        return try parser.finish()
    }
}

private extension SequenceDiagram {
    struct Parser {
        struct Block {
            let kind: BlockKind
            let line: Int
            var hasElse = false
        }

        var participants: [Participant] = []
        var events: [Event] = []
        var participantIDs: Set<String> = []
        var blocks: [Block] = []
        var activations: [String: [Int]] = [:]
        var hasReadStatement = false

        mutating func read(_ statement: String, at line: Int) throws {
            let (command, arguments) = Self.firstWord(in: statement)
            if let kind = BlockKind(rawValue: command) {
                try beginBlock(kind, label: arguments, at: line)
            } else if let kind = BranchKind(rawValue: command) {
                try addBranch(kind, label: arguments, at: line)
            } else {
                switch command {
                case "sequenceDiagram":
                    guard !hasReadStatement, arguments.isEmpty else {
                        throw ParseError(line: line, message: String(localized: "sequenceDiagram 标头须放在首个非空行。"))
                    }
                case "participant":
                    try addParticipant(arguments, at: line)
                case "Note", "note":
                    try addNote(arguments, at: line)
                case "activate", "deactivate":
                    try changeActivation(arguments, active: command == "activate", at: line)
                case "end":
                    guard arguments.isEmpty, blocks.popLast() != nil else {
                        throw ParseError(line: line, message: String(localized: "end 须单独占一行，并与一个尚未结束的片段对应。"))
                    }
                    events.append(.endBlock)
                default:
                    try addMessage(statement, at: line)
                }
            }

            guard events.count <= 600 else {
                throw ParseError(line: line, message: String(localized: "时序图最多包含 600 个事件。"))
            }
            hasReadStatement = true
        }

        mutating func addParticipant(_ arguments: String, at line: Int) throws {
            let (id, alias) = Self.firstWord(in: arguments)
            try Self.checkID(id, at: line)
            guard !participantIDs.contains(id) else {
                throw ParseError(line: line, message: String(localized: "参与者 \(id) 已声明。"))
            }
            guard participants.count < 24 else {
                throw ParseError(line: line, message: String(localized: "时序图最多包含 24 个参与者。"))
            }

            let label: String
            if alias.isEmpty {
                label = id
            } else {
                let (keyword, value) = Self.firstWord(in: alias)
                guard keyword == "as", !value.isEmpty else {
                    throw ParseError(line: line, message: String(localized: "别名须使用 participant ID as 名称。"))
                }
                label = value
            }

            try Self.checkLabel(label, at: line)
            participantIDs.insert(id)
            participants.append(Participant(id: id, label: label))
        }

        mutating func addMessage(_ statement: String, at line: Int) throws {
            let (route, label) = try Self.labelledStatement(statement, at: line)
            for kind in MessageKind.allCases {
                guard let arrow = route.range(of: kind.rawValue) else { continue }
                let from = route[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = route[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                try requireParticipant(from, at: line)
                try requireParticipant(to, at: line)
                events.append(.message(from: from, to: to, kind: kind, label: label))
                return
            }
            throw ParseError(line: line, message: String(localized: "消息须使用 ->>、-) 或 -->> 箭头。"))
        }

        mutating func addNote(_ arguments: String, at line: Int) throws {
            let (targets, label) = try Self.labelledStatement(arguments, at: line)
            let (keyword, list) = Self.firstWord(in: targets)
            let ids = list.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard keyword == "over", (1...2).contains(ids.count), Set(ids).count == ids.count else {
                throw ParseError(line: line, message: String(localized: "备注须使用 Note over ID: 文字 或 Note over ID1,ID2: 文字。"))
            }
            for id in ids {
                try requireParticipant(id, at: line)
            }
            events.append(.note(participants: ids, label: label))
        }

        mutating func changeActivation(_ id: String, active: Bool, at line: Int) throws {
            try requireParticipant(id, at: line)
            if active {
                guard (activations[id]?.count ?? 0) < 16 else {
                    throw ParseError(line: line, message: String(localized: "同一参与者的激活最多嵌套 16 层。"))
                }
                activations[id, default: []].append(line)
                events.append(.activate(participant: id))
            } else {
                guard activations[id]?.popLast() != nil else {
                    throw ParseError(line: line, message: String(localized: "参与者 \(id) 没有可结束的激活。"))
                }
                events.append(.deactivate(participant: id))
            }
        }

        mutating func beginBlock(_ kind: BlockKind, label: String, at line: Int) throws {
            guard blocks.count < 16 else {
                throw ParseError(line: line, message: String(localized: "片段最多嵌套 16 层。"))
            }
            try Self.checkLabel(label, at: line)
            blocks.append(Block(kind: kind, line: line))
            events.append(.beginBlock(kind: kind, label: label))
        }

        mutating func addBranch(_ kind: BranchKind, label: String, at line: Int) throws {
            if kind == .elseBranch {
                guard let block = blocks.last, block.kind == .alt, !block.hasElse else {
                    throw ParseError(line: line, message: String(localized: "每个 alt 片段最多包含一个 else。"))
                }
                blocks[blocks.count - 1].hasElse = true
            } else if blocks.last?.kind != .par {
                throw ParseError(line: line, message: String(localized: "and 须位于 par 片段中。"))
            }
            try Self.checkLabel(label, at: line)
            events.append(.branch(kind: kind, label: label))
        }

        func finish() throws -> SequenceDiagram {
            if let block = blocks.last {
                throw ParseError(line: block.line, message: String(localized: "\(block.kind.rawValue) 片段缺少 end。"))
            }
            let unclosed = activations.compactMap { id, lines in lines.last.map { (id, $0) } }
            if let (id, line) = unclosed.max(by: { $0.1 < $1.1 }) {
                throw ParseError(line: line, message: String(localized: "参与者 \(id) 的激活缺少 deactivate。"))
            }
            return SequenceDiagram(participants: participants, events: events)
        }

        func requireParticipant(_ id: String, at line: Int) throws {
            try Self.checkID(id, at: line)
            guard participantIDs.contains(id) else {
                throw ParseError(line: line, message: String(localized: "参与者 \(id) 尚未声明。"))
            }
        }

        static func firstWord(in value: String) -> (String, String) {
            guard let separator = value.firstIndex(where: \.isWhitespace) else { return (value, "") }
            return (String(value[..<separator]), value[separator...].trimmingCharacters(in: .whitespaces))
        }

        static func labelledStatement(_ value: String, at line: Int) throws -> (String, String) {
            guard let colon = value.firstIndex(of: ":") else {
                throw ParseError(line: line, message: String(localized: "消息和备注须用冒号引出文字。"))
            }
            let label = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else {
                throw ParseError(line: line, message: String(localized: "消息或备注的文字不能为空。"))
            }
            try checkLabel(label, at: line)
            return (String(value[..<colon]), label)
        }

        static func checkID(_ id: String, at line: Int) throws {
            let bytes = id.utf8
            guard let first = bytes.first, bytes.count <= 64, isLetterOrUnderscore(first),
                  bytes.dropFirst().allSatisfy({ isLetterOrUnderscore($0) || (48...57).contains($0) }) else {
                throw ParseError(line: line, message: String(localized: "参与者 ID 须以英文字母或下划线开头，最多 64 个英文字母、数字或下划线。"))
            }
        }

        static func isLetterOrUnderscore(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
        }

        static func checkLabel(_ label: String, at line: Int) throws {
            guard label.count <= 256, label.utf8.count <= 1_024 else {
                throw ParseError(line: line, message: String(localized: "标签最多为 256 个字符且不得超过 1 KB。"))
            }
            guard !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\t" }) else {
                throw ParseError(line: line, message: String(localized: "标签中含有不支持的控制符。"))
            }
        }
    }
}
