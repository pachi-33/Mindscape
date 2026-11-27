import Foundation

enum SequenceSelection: Equatable, Hashable, Sendable {
    case participant(String)
    case event(Int)
}

extension SequenceDiagram {
    enum Edit {
        case addParticipant(label: String)
        case renameParticipant(id: String, label: String)
        case moveParticipant(id: String, to: Int)
        case insertEvent(Event, at: Int)
        case replaceEvent(index: Int, with: Event)
        case moveEvent(index: Int, to: Int)
        case insertActivation(participant: String, at: Int, end: Int)
        case resizeActivation(index: Int, end: Int)
        case replaceActivation(index: Int, participant: String, end: Int)
        case insertFragment(kind: BlockKind, label: String, at: Int)
        case wrapFragment(kind: BlockKind, label: String, range: Range<Int>)
        case insertBranch(in: Int, at: Int, label: String)
        case delete(SequenceSelection)
    }

    enum EditError: LocalizedError {
        case unavailable
        case invalidSelection
        case invalidPosition
        case invalidLabel
        case invalidStructure(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "当前文档无法编辑时序图。")
            case .invalidSelection: String(localized: "这个时序图元素已不存在，或无法进行所选操作。")
            case .invalidPosition: String(localized: "无法在此位置放置时序图元素。")
            case .invalidLabel: String(localized: "请输入单行标签。")
            case .invalidStructure(let message): message
            }
        }
    }

    /// 索引成对的片段和激活边界。两端都可作为参数。
    func pairedEvent(for index: Int) -> Int? {
        Self.pairedEvents(in: events)[index]
    }

    /// gap 是元素之间的位置。片段开启后的第一个 gap 在片段内，结束后的 gap 在外面。
    func containingFragment(at gap: Int) -> Int? {
        guard (0...events.count).contains(gap) else { return nil }
        return Self.scope(at: gap, in: events).fragment
    }

    func applying(_ edit: Edit) throws -> (diagram: SequenceDiagram, selection: SequenceSelection?) {
        var state = EditState(diagram: self)
        let selection = try state.edit(edit)
        let candidate = SequenceDiagram(participants: state.participants, events: state.rows.map(\.event))
        do {
            let validated = try Self.parse(candidate.serializedSource)
            guard candidate == validated else { throw EditError.invalidLabel }
            try state.validateActivationPairs(in: validated)
            return (validated, selection)
        } catch let error as ParseError {
            throw EditError.invalidStructure(error.message)
        }
    }

    var serializedSource: String {
        let declarations = participants.map { participant in
            if participant.id.utf8.elementsEqual(participant.label.utf8) {
                return "participant \(participant.id)"
            }
            return "participant \(participant.id) as \(participant.label)"
        }
        let statements = events.map { event in
            switch event {
            case let .message(from, to, kind, label): "\(from)\(kind.rawValue)\(to): \(label)"
            case let .note(participants, label): "Note over \(participants.joined(separator: ",")): \(label)"
            case .activate(let participant): "activate \(participant)"
            case .deactivate(let participant): "deactivate \(participant)"
            case let .beginBlock(kind, label): "\(kind.rawValue) \(label)".trimmingCharacters(in: .whitespaces)
            case let .branch(kind, label): "\(kind.rawValue) \(label)".trimmingCharacters(in: .whitespaces)
            case .endBlock: "end"
            }
        }
        return (declarations + statements).joined(separator: "\n")
    }
}

private extension SequenceDiagram {
    struct Scope: Equatable {
        var fragment: Int?
        var branch: Int?
    }

    static func scope(at gap: Int, in events: [Event]) -> Scope {
        var scopes = [Scope()]
        for (index, event) in events.prefix(gap).enumerated() {
            switch event {
            case .beginBlock: scopes.append(Scope(fragment: index))
            case .branch: scopes[scopes.count - 1].branch = index
            case .endBlock:
                if scopes.count > 1 { scopes.removeLast() }
            default: break
            }
        }
        return scopes.last ?? Scope()
    }

    static func pairedEvents(in events: [Event]) -> [Int: Int] {
        var fragments: [Int] = []
        var activations: [String: [Int]] = [:]
        var pairs: [Int: Int] = [:]
        for (index, event) in events.enumerated() {
            let opening: Int?
            switch event {
            case .beginBlock:
                fragments.append(index)
                opening = nil
            case .activate(let participant):
                activations[participant, default: []].append(index)
                opening = nil
            case .endBlock:
                opening = fragments.popLast()
            case .deactivate(let participant):
                opening = activations[participant]?.popLast()
            default:
                opening = nil
            }
            if let opening {
                pairs[opening] = index
                pairs[index] = opening
            }
        }
        return pairs
    }

    struct EditState {
        struct Row {
            let id: Int
            var event: Event
        }

        var participants: [Participant]
        var rows: [Row]
        private var nextID: Int
        private var activationPairs: [Int: Int]

        init(diagram: SequenceDiagram) {
            participants = diagram.participants
            rows = diagram.events.enumerated().map { Row(id: $0.offset, event: $0.element) }
            nextID = rows.count
            activationPairs = SequenceDiagram.pairedEvents(in: diagram.events).filter { opening, closing in
                if case .activate = diagram.events[opening] { return opening < closing }
                return false
            }
        }

        mutating func edit(_ edit: Edit) throws -> SequenceSelection? {
            switch edit {
            case let .addParticipant(label):
                let id = "P" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                var name = try Self.label(label, required: false)
                if name.isEmpty {
                    let used = Set(participants.map(\.label))
                    var suffix = participants.count + 1
                    name = String(localized: "参与者 \(suffix)")
                    while used.contains(name) {
                        suffix += 1
                        name = String(localized: "参与者 \(suffix)")
                    }
                }
                participants.append(Participant(id: id, label: name))
                return .participant(id)
            case let .renameParticipant(id, label):
                let index = try participantIndex(id)
                participants[index] = Participant(id: id, label: try Self.label(label))
                return .participant(id)
            case let .moveParticipant(id, gap):
                let index = try participantIndex(id)
                guard (0...participants.count).contains(gap) else { throw EditError.invalidPosition }
                let participant = participants.remove(at: index)
                participants.insert(participant, at: gap > index ? gap - 1 : gap)
                return .participant(id)
            case let .insertEvent(event, gap):
                try checkGap(gap)
                let row = makeRow(try Self.messageOrNote(event))
                rows.insert(row, at: gap)
                return .event(gap)
            case let .replaceEvent(index, event):
                return try replaceEvent(at: index, with: event)
            case let .moveEvent(index, gap):
                return try moveEvent(at: index, to: gap)
            case let .insertActivation(participant, start, end):
                try checkGap(start)
                try checkGap(end)
                guard start <= end else { throw EditError.invalidPosition }
                let opening = makeRow(.activate(participant: participant))
                let closing = makeRow(.deactivate(participant: participant))
                activationPairs[opening.id] = closing.id
                rows.insert(closing, at: end)
                rows.insert(opening, at: start)
                return .event(start)
            case let .resizeActivation(index, gap):
                return try resizeActivation(at: index, to: gap)
            case let .replaceActivation(index, participant, gap):
                let pair = try activationRange(at: index)
                setActivationParticipant(participant, in: pair)
                return try resizeActivation(pair, to: gap)
            case let .insertFragment(kind, label, gap):
                try checkGap(gap)
                return try wrapFragment(kind, label: label, range: gap..<gap)
            case let .wrapFragment(kind, label, range):
                return try wrapFragment(kind, label: label, range: range)
            case let .insertBranch(fragment, gap, label):
                return try insertBranch(in: fragment, at: gap, label: label)
            case let .delete(selection):
                try delete(selection)
                return nil
            }
        }

        mutating func replaceEvent(at index: Int, with replacement: Event) throws -> SequenceSelection {
            try checkEvent(index)
            switch (rows[index].event, replacement) {
            case (.message, .message), (.note, .note):
                rows[index].event = try Self.messageOrNote(replacement)
            case let (.beginBlock, .beginBlock(kind, label)):
                let sources = rows.map(\.event)
                if let end = SequenceDiagram.pairedEvents(in: sources)[index] {
                    let newKind = Self.branchKind(for: kind)
                    for child in (index + 1)..<end {
                        guard case .branch(_, let branchLabel) = sources[child],
                              SequenceDiagram.scope(at: child, in: sources).fragment == index else { continue }
                        guard let newKind else { throw EditError.invalidPosition }
                        rows[child].event = .branch(kind: newKind, label: branchLabel)
                    }
                }
                rows[index].event = .beginBlock(kind: kind, label: try Self.label(label, required: false))
            case let (.branch(current, _), .branch(_, label)):
                rows[index].event = .branch(kind: current, label: try Self.label(label, required: false))
            case let (.activate, .activate(participant)), let (.deactivate, .activate(participant)):
                let pair = try activationRange(at: index)
                setActivationParticipant(participant, in: pair)
                return .event(pair.lowerBound)
            default:
                throw EditError.invalidSelection
            }
            return .event(index)
        }

        mutating func moveEvent(at index: Int, to gap: Int) throws -> SequenceSelection {
            try checkEvent(index)
            try checkGap(gap)
            let events = rows.map(\.event)
            let range: ClosedRange<Int>
            switch rows[index].event {
            case .activate, .deactivate:
                let pair = try activationRange(at: index)
                return try moveActivation(pair, to: gap)
            case .beginBlock, .endBlock:
                guard let paired = SequenceDiagram.pairedEvents(in: events)[index] else { throw EditError.invalidSelection }
                range = min(index, paired)...max(index, paired)
            case .branch:
                let scope = SequenceDiagram.scope(at: index, in: events)
                guard scope.fragment == SequenceDiagram.scope(at: gap, in: events).fragment else {
                    throw EditError.invalidPosition
                }
                range = index...index
            default:
                range = index...index
            }

            if (range.lowerBound...(range.upperBound + 1)).contains(gap) {
                guard gap == range.lowerBound || gap == range.upperBound + 1 else { throw EditError.invalidPosition }
                return .event(range.lowerBound)
            }
            let moving = Array(rows[range])
            rows.removeSubrange(range)
            let destination = gap > range.upperBound ? gap - moving.count : gap
            rows.insert(contentsOf: moving, at: destination)
            return .event(destination)
        }

        mutating func moveActivation(_ pair: ClosedRange<Int>, to gap: Int) throws -> SequenceSelection {
            let start = pair.lowerBound
            let end = pair.upperBound
            guard gap != start, gap != start + 1 else { return .event(start) }
            let closing = rows.remove(at: end)
            let opening = rows.remove(at: start)
            let destination = gap - (gap > start ? 1 : 0) - (gap > end ? 1 : 0)
            let newEnd = destination + end - start - 1
            guard newEnd <= rows.count else { throw EditError.invalidPosition }
            rows.insert(closing, at: newEnd)
            rows.insert(opening, at: destination)
            return .event(destination)
        }

        mutating func resizeActivation(at index: Int, to gap: Int) throws -> SequenceSelection {
            let pair = try activationRange(at: index)
            return try resizeActivation(pair, to: gap)
        }

        mutating func resizeActivation(_ pair: ClosedRange<Int>, to gap: Int) throws -> SequenceSelection {
            try checkGap(gap)
            guard gap > pair.lowerBound else { throw EditError.invalidPosition }
            let closing = rows.remove(at: pair.upperBound)
            rows.insert(closing, at: gap > pair.upperBound ? gap - 1 : gap)
            return .event(pair.lowerBound)
        }

        mutating func setActivationParticipant(_ participant: String, in pair: ClosedRange<Int>) {
            rows[pair.lowerBound].event = .activate(participant: participant)
            rows[pair.upperBound].event = .deactivate(participant: participant)
        }

        mutating func wrapFragment(_ kind: BlockKind, label: String, range: Range<Int>) throws -> SequenceSelection {
            try checkGap(range.lowerBound)
            try checkGap(range.upperBound)
            let events = rows.map(\.event)
            guard SequenceDiagram.scope(at: range.lowerBound, in: events) == SequenceDiagram.scope(at: range.upperBound, in: events) else {
                throw EditError.invalidPosition
            }
            let opening = makeRow(.beginBlock(kind: kind, label: try Self.label(label, required: false)))
            let closing = makeRow(.endBlock)
            rows.insert(closing, at: range.upperBound)
            rows.insert(opening, at: range.lowerBound)
            return .event(range.lowerBound)
        }

        mutating func insertBranch(in fragment: Int, at gap: Int, label: String) throws -> SequenceSelection {
            try checkEvent(fragment)
            try checkGap(gap)
            guard case .beginBlock(let kind, _) = rows[fragment].event, let branch = Self.branchKind(for: kind),
                  SequenceDiagram.scope(at: gap, in: rows.map(\.event)).fragment == fragment else {
                throw EditError.invalidPosition
            }
            let row = makeRow(.branch(kind: branch, label: try Self.label(label, required: false)))
            rows.insert(row, at: gap)
            return .event(gap)
        }

        mutating func delete(_ selection: SequenceSelection) throws {
            switch selection {
            case .participant(let id):
                participants.remove(at: try participantIndex(id))
                rows = rows.compactMap { row in
                    switch row.event {
                    case let .message(from, to, _, _) where from == id || to == id:
                        return nil
                    case .activate(let participant) where participant == id,
                         .deactivate(let participant) where participant == id:
                        return nil
                    case let .note(targets, label) where targets.contains(id):
                        let remaining = targets.filter { $0 != id }
                        return remaining.isEmpty ? nil : Row(id: row.id, event: .note(participants: remaining, label: label))
                    default:
                        return row
                    }
                }
            case .event(let index):
                try checkEvent(index)
                switch rows[index].event {
                case .beginBlock, .endBlock:
                    guard let paired = SequenceDiagram.pairedEvents(in: rows.map(\.event))[index] else { throw EditError.invalidSelection }
                    let fragment = min(index, paired)...max(index, paired)
                    let deletedIDs = Set(rows[fragment].map(\.id))
                    let activationIDs = activationPairs.reduce(into: deletedIDs) { ids, pair in
                        if deletedIDs.contains(pair.key) || deletedIDs.contains(pair.value) {
                            ids.insert(pair.key)
                            ids.insert(pair.value)
                        }
                    }
                    rows.removeAll { activationIDs.contains($0.id) }
                case .activate, .deactivate:
                    let pair = try activationRange(at: index)
                    rows.remove(at: pair.upperBound)
                    rows.remove(at: pair.lowerBound)
                default:
                    rows.remove(at: index)
                }
            }
        }

        func validateActivationPairs(in diagram: SequenceDiagram) throws {
            let indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            let pairedEvents = SequenceDiagram.pairedEvents(in: diagram.events)
            for (opening, closing) in activationPairs {
                let start = indices[opening]
                let end = indices[closing]
                if start == nil && end == nil { continue }
                guard let start, let end, start < end, pairedEvents[start] == end else {
                    throw EditError.invalidPosition
                }
            }
        }

        private func activationRange(at index: Int) throws -> ClosedRange<Int> {
            try checkEvent(index)
            switch rows[index].event {
            case .activate, .deactivate:
                guard let other = SequenceDiagram.pairedEvents(in: rows.map(\.event))[index] else { throw EditError.invalidSelection }
                return min(index, other)...max(index, other)
            default:
                throw EditError.invalidSelection
            }
        }

        private func participantIndex(_ id: String) throws -> Int {
            guard let index = participants.firstIndex(where: { $0.id == id }) else { throw EditError.invalidSelection }
            return index
        }

        private func checkEvent(_ index: Int) throws {
            guard rows.indices.contains(index) else { throw EditError.invalidSelection }
        }

        private func checkGap(_ index: Int) throws {
            guard (0...rows.count).contains(index) else { throw EditError.invalidPosition }
        }

        private mutating func makeRow(_ event: Event) -> Row {
            defer { nextID += 1 }
            return Row(id: nextID, event: event)
        }

        private static func branchKind(for kind: BlockKind) -> BranchKind? {
            switch kind {
            case .alt: .elseBranch
            case .par: .andBranch
            case .loop, .opt: nil
            }
        }

        private static func label(_ input: String, required: Bool = true) throws -> String {
            guard !input.contains(where: \.isNewline) else { throw EditError.invalidLabel }
            let value = input.trimmingCharacters(in: .whitespaces)
            guard !required || !value.isEmpty else { throw EditError.invalidLabel }
            return value
        }

        private static func messageOrNote(_ event: Event) throws -> Event {
            switch event {
            case let .message(from, to, kind, label):
                return .message(from: from, to: to, kind: kind, label: try Self.label(label))
            case let .note(participants, label):
                return .note(participants: participants, label: try Self.label(label))
            default:
                throw EditError.invalidSelection
            }
        }
    }
}
