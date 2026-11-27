import Foundation

enum SequenceEditingScope: Hashable {
    case root
    case fragment(Int)
    case branch(Int)

    var eventIndex: Int? {
        switch self {
        case .root: nil
        case let .fragment(index), let .branch(index): index
        }
    }
}

/// Adapts parser event positions to the operands and sibling rows exposed by the editor.
struct SequenceEditingStructure {
    private let diagram: SequenceDiagram
    private let gapScopes: [SequenceEditingScope]
    private let endGaps: [SequenceEditingScope: Int]
    private let enclosingScopes: [SequenceEditingScope: SequenceEditingScope]
    private let fragmentIDs: [SequenceEditingScope: Int]
    private let siblings: [SequenceEditingScope: [Int]]
    let scopes: [SequenceEditingScope]

    init(diagram: SequenceDiagram) {
        struct Frame {
            let index: Int
            let enclosing: SequenceEditingScope
            var operand: SequenceEditingScope
        }

        var stack: [Frame] = []
        var gapScopes: [SequenceEditingScope] = []
        var endGaps: [SequenceEditingScope: Int] = [.root: diagram.events.count]
        var enclosingScopes: [SequenceEditingScope: SequenceEditingScope] = [:]
        var fragmentIDs: [SequenceEditingScope: Int] = [:]
        var siblings: [SequenceEditingScope: [Int]] = [:]
        var scopes: [SequenceEditingScope] = [.root]

        for (index, event) in diagram.events.enumerated() {
            let scope = stack.last?.operand ?? .root
            gapScopes.append(scope)
            switch event {
            case .beginBlock:
                siblings[scope, default: []].append(index)
                let operand = SequenceEditingScope.fragment(index)
                stack.append(Frame(index: index, enclosing: scope, operand: operand))
                enclosingScopes[operand] = scope
                fragmentIDs[operand] = index
                scopes.append(operand)
            case .branch:
                guard var frame = stack.popLast() else { continue }
                endGaps[frame.operand] = index
                frame.operand = .branch(index)
                stack.append(frame)
                enclosingScopes[frame.operand] = frame.enclosing
                fragmentIDs[frame.operand] = frame.index
                scopes.append(frame.operand)
            case .endBlock:
                guard let frame = stack.popLast() else { continue }
                endGaps[frame.operand] = index
            case .deactivate:
                break
            default:
                siblings[scope, default: []].append(index)
            }
        }
        gapScopes.append(.root)
        self.diagram = diagram
        self.gapScopes = gapScopes
        self.endGaps = endGaps
        self.enclosingScopes = enclosingScopes
        self.fragmentIDs = fragmentIDs
        self.siblings = siblings
        self.scopes = scopes
    }

    func scope(at gap: Int) -> SequenceEditingScope {
        gapScopes.indices.contains(gap) ? gapScopes[gap] : .root
    }

    func scope(for eventIndex: Int) -> SequenceEditingScope {
        guard diagram.events.indices.contains(eventIndex) else { return .root }
        switch diagram.events[eventIndex] {
        case .beginBlock: return .fragment(eventIndex)
        case .branch: return .branch(eventIndex)
        default: return scope(at: eventIndex)
        }
    }

    func enclosingScope(of scope: SequenceEditingScope) -> SequenceEditingScope {
        enclosingScopes[scope] ?? .root
    }

    func end(of scope: SequenceEditingScope) -> Int { endGaps[scope] ?? diagram.events.count }

    func fragmentAcceptingBranch(in scope: SequenceEditingScope) -> Int? {
        guard let index = fragmentIDs[scope], let end = diagram.pairedEvent(for: index),
              case let .beginBlock(kind, _) = diagram.events[index] else { return nil }
        switch kind {
        case .par: return index
        case .alt:
            let hasElse = scopes.contains { scope in
                guard case let .branch(branch) = scope else { return false }
                return index < branch && branch < end && fragmentIDs[scope] == index
            }
            return hasElse ? nil : index
        case .loop, .opt: return nil
        }
    }

    func immediatelyAfter(event index: Int) -> Int {
        switch diagram.events[index] {
        case .activate, .beginBlock: return (diagram.pairedEvent(for: index) ?? index) + 1
        default: return index + 1
        }
    }

    func siblingGap(for index: Int, direction: Int) -> Int? {
        let rows = siblings[scope(at: index), default: []]
        guard let current = rows.firstIndex(of: index), rows.indices.contains(current + direction) else { return nil }
        let sibling = rows[current + direction]
        return direction < 0 ? sibling : immediatelyAfter(event: sibling)
    }

    func label(for scope: SequenceEditingScope) -> String {
        guard let index = scope.eventIndex else { return String(localized: "整个时序图") }
        let depth = depth(of: scope)
        return String(repeating: "  ", count: max(0, depth - 1)) + eventLabel(at: index)
    }

    func eventLabel(at index: Int) -> String {
        switch diagram.events[index] {
        case let .message(from, to, _, label):
            return "\(name(of: from)) → \(name(of: to)) · \(label)"
        case let .note(_, label): return label
        case let .activate(id): return String(localized: "激活 \(name(of: id))")
        case let .deactivate(id): return String(localized: "结束 \(name(of: id)) 的激活")
        case let .beginBlock(kind, label): return label.isEmpty ? kind.rawValue : "\(kind.rawValue) · \(label)"
        case let .branch(kind, label): return label.isEmpty ? kind.rawValue : "\(kind.rawValue) · \(label)"
        case .endBlock: return String(localized: "片段结束")
        }
    }

    private func name(of id: String) -> String {
        diagram.participants.first { $0.id == id }?.label ?? id
    }

    private func depth(of scope: SequenceEditingScope) -> Int {
        var count = 0
        var scope = scope
        while let enclosing = enclosingScopes[scope] {
            count += 1
            scope = enclosing
        }
        return count
    }
}
