import AppKit
import SwiftUI

struct SequenceWorkspaceView: View {
    let editor: MapEditor

    @State private var diagram = SequenceDiagram(participants: [], events: [])
    @State private var appliedSource: String?
    @State private var sourceError: String?
    @State private var editError: String?
    @State private var selection: SequenceSelection?
    @State private var scope = SequenceEditingScope.root
    @State private var draft: SequenceDraft?
    @State private var defaults: [SequenceTool: SequenceDraft] = [:]
    @State private var placement = SequencePlacement.append
    @State private var laneClick = SequenceLaneClick.none
    @State private var reveal: SequenceReveal?
    @State private var camera = SequenceGraphicCamera()
    @State private var showInspector = true
    @State private var showThemePicker = false
    @State private var showHistory = false
    @State private var showExport = false
    @State private var showOutline = false
    @State private var outlineQuery = ""
    @State private var deleteTarget: SequenceSelection?
    @State private var snapshotFeedback: SnapshotFeedback?
    @FocusState private var labelFocused: Bool

    private struct SnapshotFeedback: Equatable {
        let id = UUID()
        let success: Bool
    }

    private var structure: SequenceEditingStructure { SequenceEditingStructure(diagram: diagram) }
    private var branchFrame: Int? { structure.fragmentAcceptingBranch(in: scope) }

    var body: some View {
        canvasArea
            .navigationTitle("")
            .inspector(isPresented: $showInspector) {
                inspector
                    .inspectorColumnWidth(min: 248, ideal: 292, max: 380)
            }
            .toolbar { toolbarContent }
            .sheet(isPresented: $showHistory) { HistoryView(editor: editor) }
            .sheet(isPresented: $showExport) { ExportSheet(editor: editor) }
            .sheet(isPresented: $showOutline) { outline }
            .alert("删除所选元素？", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    if let target = deleteTarget { delete(target) }
                    deleteTarget = nil
                }
            } message: {
                Text(deleteExplanation)
            }
            .onChange(of: editor.map.sequenceSource, initial: true) { _, _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: .mindscapeShowHistory)) { _ in showHistory = true }
            .onReceive(NotificationCenter.default.publisher(for: .mindscapeShowExport)) { _ in showExport = true }
            .onReceive(NotificationCenter.default.publisher(for: .mindscapeFind)) { _ in showOutline = true }
            .onReceive(NotificationCenter.default.publisher(for: .mindscapeToggleInspector)) { _ in showInspector.toggle() }
            .onReceive(NotificationCenter.default.publisher(for: .mindscapeToggleOutline)) { _ in showOutline.toggle() }
            .onChange(of: editor.fitToken) { _, _ in camera.fitWidth() }
            .onChange(of: editor.centerContentToken) { _, _ in camera.center() }
            .onChange(of: editor.zoomToken) { _, _ in camera.step(editor.zoomFactor) }
            .onReceive(NotificationCenter.default.publisher(for: .mindscapeSnapshotCreated)) { note in
                snapshotFeedback = SnapshotFeedback(success: note.object as? Bool ?? false)
            }
            .task(id: snapshotFeedback) {
                guard snapshotFeedback != nil else { return }
                try? await Task.sleep(for: .seconds(1.8))
                if !Task.isCancelled { snapshotFeedback = nil }
            }
    }

    private var canvasArea: some View {
        Group {
            if let sourceError {
                ContentUnavailableView {
                    Label("无法显示时序图", systemImage: "exclamationmark.circle")
                } description: {
                    Text(sourceError)
                        .accessibilityIdentifier("sequence.diagnostic")
                } actions: {
                    Button("导出") { showExport = true }
                }
            } else if diagram.participants.isEmpty {
                ContentUnavailableView {
                    Label("添加第一位参与者", systemImage: MapTemplate.sequence.symbol)
                } actions: {
                    Button("添加参与者") { start(.participant) }
                        .accessibilityIdentifier("sequence.canvas.add.participant")
                }
            } else {
                SequenceGraphicCanvas(
                    diagram: diagram,
                    theme: editor.theme,
                    selection: selection,
                    reveal: reveal,
                    camera: camera,
                    onSelect: { select($0, focus: false) },
                    onEdit: { select($0, focus: true) },
                    onLaneClick: laneClick == .none ? nil : chooseLane,
                    onMoveParticipant: { id, gap in move(.participant(id), to: gap) },
                    onMoveEvent: { index, gap in move(.event(index), to: gap) }
                )
                .overlay(alignment: .bottom) {
                    SequenceGraphicZoomBar(camera: camera)
                        .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: editor.theme.background))
        .overlay(alignment: .top) {
            if let editError {
                HStack(spacing: 7) {
                    Label(editError, systemImage: "exclamationmark.circle.fill")
                        .accessibilityIdentifier("sequence.editError")
                    Button { self.editError = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            } else if let snapshotFeedback {
                Label(
                    LocalizedStringKey(snapshotFeedback.success ? "快照已创建" : "创建快照失败"),
                    systemImage: snapshotFeedback.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            toolButtons
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if sourceError == nil {
                scopePicker
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                Divider()
                ScrollView {
                    if let draft {
                        form(draft.bound(to: $draft))
                            .padding(12)
                    } else {
                        Text("在画布上选中元素，或使用上方按钮添加元素。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                if let draft {
                    Divider()
                    formActions(draft)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var toolButtons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
            ForEach(SequenceTool.allCases) { tool in
                Button {
                    start(tool)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 13, weight: .medium))
                        Text(tool.title)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tool.addTitle)
                .accessibilityLabel(tool.addTitle)
                .accessibilityIdentifier("sequence.add.\(tool.rawValue)")
                .disabled(!canAdd(tool))
            }
        }
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("编辑范围")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    navigate(to: structure.enclosingScope(of: scope))
                } label: {
                    Label("离开片段", systemImage: "arrow.turn.up.left")
                }
                .controlSize(.small)
                .accessibilityIdentifier("sequence.scope.up")
                .disabled(scope == .root)
            }
            Picker("编辑范围", selection: Binding(get: { scope }, set: { navigate(to: $0) })) {
                ForEach(structure.scopes, id: \.self) { option in
                    Text(structure.label(for: option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityIdentifier("sequence.scope")
        }
    }

    private func form(_ draft: Binding<SequenceDraft>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            let value = draft.wrappedValue
            Text(value.target == nil ? value.tool.addTitle : value.tool.editTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            switch value.tool {
            case .participant:
                labelField("名称", text: draft.label)
            case .message:
                participantPicker("发送方", id: "from", participant: manualEndpoint(draft.from, session: value.session))
                participantPicker("接收方", id: "to", participant: manualEndpoint(draft.to, session: value.session))
                field("箭头", id: "arrow", value: draft.arrow) {
                    ForEach(SequenceDiagram.MessageKind.allCases, id: \.self) { kind in
                        Text(kind.uiTitle).tag(kind)
                    }
                }
                labelField("消息文字", text: draft.label)
                if laneClick != .none {
                    Text(laneClick == .from ? "也可以在画布上点选发送方。" : "在画布上点选接收方。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .note:
                participantPicker("起始参与者", id: "from", participant: Binding(
                    get: { draft.from.wrappedValue },
                    set: { id in
                        draft.from.wrappedValue = id
                        if draft.to.wrappedValue == id { draft.to.wrappedValue = "" }
                    }
                ))
                participantPicker("结束参与者", id: "to", participant: draft.to, optional: true,
                                  excluding: value.from)
                labelField("备注内容", text: draft.label)
            case .activation:
                participantPicker("参与者", id: "from", participant: draft.from)
                activationEnd(for: draft)
            case .fragment:
                field("操作符", id: "fragment", value: draft.block) {
                    ForEach(SequenceDraft.blockKinds, id: \.self) { kind in
                        Text(kind.uiTitle).tag(kind)
                    }
                }
                labelField("片段条件", text: draft.label)
            case .branch:
                labelField("分支条件", text: draft.label)
            }

            if value.target == nil, value.tool.canPlaceRelative, selectedEventIndex != nil {
                field("插入位置", id: "placement", value: $placement) {
                    ForEach(SequencePlacement.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
        }
    }

    private func labelField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(title, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .focused($labelFocused)
                .accessibilityIdentifier("sequence.field.label")
        }
    }

    private func participantPicker(_ title: LocalizedStringKey, id: String, participant: Binding<String>,
                                   optional: Bool = false, excluding: String? = nil) -> some View {
        field(title, id: id, value: participant) {
            if optional { Text("仅覆盖一条生命线").tag("") }
            ForEach(diagram.participants.filter { $0.id != excluding }, id: \.id) { item in
                Text(item.label).tag(item.id)
            }
        }
    }

    private func manualEndpoint(_ value: Binding<String>, session: UUID) -> Binding<String> {
        Binding(get: { value.wrappedValue }, set: { id in
            guard draft?.session == session else { return }
            value.wrappedValue = id
            laneClick = .none
        })
    }

    private func field<Value: Hashable, Options: View>(
        _ title: LocalizedStringKey,
        id: String,
        value: Binding<Value>,
        @ViewBuilder options: () -> Options
    ) -> some View {
        Picker(title, selection: value, content: options)
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityIdentifier("sequence.field.\(id)")
    }

    private func activationEnd(for draft: Binding<SequenceDraft>) -> some View {
        let target = draft.wrappedValue.target
        let start = target.flatMap { eventIndex(of: $0) }.map { $0 + 1 } ?? insertionGap
        let available = start < diagram.events.count
            ? Array(start..<diagram.events.count).filter { index in
                if case .deactivate = diagram.events[index] { return false }
                return true
            }
            : []
        let end = Binding(
            get: { draft.end.wrappedValue >= start ? draft.end.wrappedValue : -1 },
            set: { draft.end.wrappedValue = $0 }
        )
        return field("激活结束位置", id: "activationEnd", value: end) {
            Text("紧接激活开始").tag(-1)
            ForEach(available, id: \.self) { index in
                Text("在 \(index + 1). \(structure.eventLabel(at: index)) 前").tag(index)
            }
            Text("时序图末尾").tag(diagram.events.count)
            if end.wrappedValue >= start,
               end.wrappedValue < diagram.events.count,
               !available.contains(end.wrappedValue) {
                Text("保持当前位置").tag(end.wrappedValue)
            }
        }
    }

    private func formActions(_ draft: SequenceDraft) -> some View {
        HStack(spacing: 6) {
            if let target = draft.target {
                Button {
                    deleteTarget = target
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除")
                .accessibilityLabel("删除")
                .accessibilityIdentifier("sequence.delete")
                moveMenu(for: target)
            } else {
                Button("取消") { cancelDraft() }
            }
            Spacer(minLength: 2)
            Button {
                if let active = self.draft, active.session == draft.session {
                    commit(active)
                }
            } label: {
                if draft.target == nil { Text("添加") } else { Text("应用") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sequence.confirm")
            .disabled(!canCommit(draft))
        }
        .controlSize(.small)
        .padding(10)
    }

    private func moveMenu(for target: SequenceSelection) -> some View {
        let previous = adjacentGap(for: target, direction: -1)
        let next = adjacentGap(for: target, direction: 1)
        return Menu("移动元素") {
            Button("上移") { if let previous { move(target, to: previous) } }
                .disabled(previous == nil)
            Button("下移") { if let next { move(target, to: next) } }
                .disabled(next == nil)
            if case let .event(index) = target, diagram.events.indices.contains(index) {
                Divider()
                Menu("移到范围末尾") {
                    ForEach(structure.scopes, id: \.self) { option in
                        let gap = structure.end(of: option)
                        Button(structure.label(for: option)) { move(target, to: gap) }
                            .disabled((index...structure.immediatelyAfter(event: index)).contains(gap))
                    }
                }
            }
        }
        .fixedSize()
        .accessibilityIdentifier("sequence.move")
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("时序元素")
                    .font(.headline)
                Spacer()
                Button("完成") { showOutline = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            TextField("查找参与者或事件", text: $outlineQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sequence.outline.search")
                .padding(.horizontal, 14)
            List {
                ForEach(diagram.participants.filter { matches($0.label) }, id: \.id) { participant in
                    Button(participant.label) { jump(to: .participant(participant.id)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sequence.outline.participant.\(participant.id)")
                }
                ForEach(diagram.events.indices.filter { isOutlineRow($0) }, id: \.self) { index in
                    Button(structure.eventLabel(at: index)) { jump(to: .event(index)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sequence.outline.event.\(index)")
                }
            }
        }
        .frame(width: 440, height: 440)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TextField("未命名时序图", text: Binding(get: { editor.map.title }, set: editor.setTitle))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .frame(width: 180)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .accessibilityIdentifier("sequence.title")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(SequenceTool.allCases) { tool in
                    Button { start(tool) } label: { Label(tool.addTitle, systemImage: tool.symbol) }
                        .disabled(!canAdd(tool))
                }
            } label: {
                Label("添加元素", systemImage: "plus")
            }
            .disabled(sourceError != nil)
            .help("添加元素")

            Button { start(.message) } label: {
                Label("连接参与者", systemImage: "arrow.right")
            }
            .disabled(!canAdd(.message))
            .help("连接参与者")
            .accessibilityIdentifier("sequence.connect")

            Button { showOutline = true } label: {
                Label("时序元素", systemImage: "list.bullet.indent")
            }
            .help("查找时序元素…")
            .accessibilityIdentifier("sequence.outline")

            Button { showThemePicker.toggle() } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: editor.theme.accent))
                        .frame(width: 8, height: 8)
                    Text(editor.theme.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(width: 92, height: 24)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("切换主题")
            .accessibilityLabel("切换主题")
            .accessibilityIdentifier("sequence.theme")
            .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
                ThemePickerGrid(selectedID: editor.map.themeID) { themeID in
                    editor.setTheme(themeID)
                    showThemePicker = false
                }
                .padding(10)
                .frame(width: 236)
                .accessibilityIdentifier("sequence.themePicker")
            }

            Button { showHistory = true } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
            .help("历史版本")

            Button { showExport = true } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出 / 分享")

            Button { showInspector.toggle() } label: {
                Label("显示 / 隐藏属性面板", systemImage: "sidebar.right")
            }
            .help("显示 / 隐藏属性面板")
            .accessibilityIdentifier("sequence.inspector")
        }
    }

    // MARK: - Editing

    private var selectedEventIndex: Int? { selection.flatMap(eventIndex(of:)) }

    private var insertionGap: Int {
        guard let index = selectedEventIndex else { return structure.end(of: scope) }
        switch placement {
        case .append: return structure.end(of: scope)
        case .before: return index
        case .after: return structure.immediatelyAfter(event: index)
        }
    }

    private var deleteExplanation: LocalizedStringKey {
        switch deleteTarget {
        case .participant: "该参与者的消息和激活也会被删除。"
        case let .event(index) where diagram.events.indices.contains(index):
            if case .beginBlock = diagram.events[index] { "该片段中的元素也会被删除。" }
            else { "可以撤销此操作。" }
        default: "可以撤销此操作。"
        }
    }

    private func reload() {
        let source = editor.map.sequenceSource
        guard source != appliedSource else { return }
        appliedSource = source
        do {
            diagram = try editor.sequenceDiagram
            sourceError = nil
        } catch {
            diagram = SequenceDiagram(participants: [], events: [])
            sourceError = error.localizedDescription
        }
        scope = .root
        selection = nil
        cancelDraft()
    }

    private func canAdd(_ tool: SequenceTool) -> Bool {
        guard sourceError == nil else { return false }
        switch tool {
        case .participant: return true
        case .branch: return branchFrame != nil
        default: return !diagram.participants.isEmpty
        }
    }

    private func canCommit(_ draft: SequenceDraft) -> Bool {
        guard draft.target != nil || canAdd(draft.tool) else { return false }
        switch draft.tool {
        case .participant, .message, .note:
            return !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }

    private func start(_ tool: SequenceTool) {
        guard canAdd(tool) else { return }
        editError = nil
        showInspector = true
        placement = .append
        let first = diagram.participants.first?.id ?? ""
        let second = diagram.participants.dropFirst().first?.id ?? first
        var value = defaults[tool] ?? SequenceDraft(tool: tool, from: first, to: tool == .note ? "" : second)
        value.session = UUID()
        if !diagram.participants.contains(where: { $0.id == value.from }) { value.from = first }
        if !value.to.isEmpty, !diagram.participants.contains(where: { $0.id == value.to }) {
            value.to = tool == .note ? "" : second
        }
        draft = value
        laneClick = tool == .message ? .from : .none
        labelFocused = tool != .activation
    }

    private func cancelDraft() {
        draft = nil
        laneClick = .none
        placement = .append
        editError = nil
        labelFocused = false
    }

    private func navigate(to target: SequenceEditingScope) {
        scope = target
        selection = target.eventIndex.map(SequenceSelection.event)
        cancelDraft()
        if let selection { reveal = SequenceReveal(selection: selection) }
    }

    private func select(_ target: SequenceSelection?, focus: Bool) {
        selection = target
        cancelDraft()
        guard let target, let value = makeDraft(for: target) else { return }
        if let index = eventIndex(of: target) {
            scope = structure.scope(for: index)
        }
        draft = value
        showInspector = true
        labelFocused = focus && value.tool != .activation
    }

    private func chooseLane(_ id: String) {
        guard draft?.tool == .message else { return }
        switch laneClick {
        case .from:
            draft?.from = id
            laneClick = .to
        case .to:
            draft?.to = id
            laneClick = .none
            labelFocused = true
        case .none:
            break
        }
    }

    private func makeDraft(for selection: SequenceSelection) -> SequenceDraft? {
        if case let .participant(id) = selection {
            guard let participant = diagram.participants.first(where: { $0.id == id }) else { return nil }
            return SequenceDraft(tool: .participant, target: selection, label: participant.label)
        }
        guard let index = eventIndex(of: selection) else { return nil }
        switch diagram.events[index] {
        case let .message(from, to, kind, label):
            return SequenceDraft(tool: .message, target: selection, label: label, from: from, to: to, arrow: kind)
        case let .note(participants, label):
            return SequenceDraft(tool: .note, target: selection, label: label, from: participants.first ?? "",
                                 to: participants.dropFirst().first ?? "")
        case let .activate(participant):
            return SequenceDraft(tool: .activation, target: selection, from: participant,
                                 end: diagram.pairedEvent(for: index) ?? -1)
        case let .beginBlock(kind, label):
            return SequenceDraft(tool: .fragment, target: selection, label: label, block: kind)
        case let .branch(_, label):
            return SequenceDraft(tool: .branch, target: selection, label: label)
        case .deactivate, .endBlock:
            return nil
        }
    }

    private func edit(for draft: SequenceDraft, at gap: Int) -> SequenceDiagram.Edit? {
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = draft.target.flatMap(eventIndex(of:))
        switch draft.tool {
        case .participant:
            if case let .participant(id) = draft.target { return .renameParticipant(id: id, label: label) }
            return .addParticipant(label: label)
        case .message:
            let event = SequenceDiagram.Event.message(from: draft.from, to: draft.to, kind: draft.arrow, label: label)
            if let index { return .replaceEvent(index: index, with: event) }
            return .insertEvent(event, at: gap)
        case .note:
            let participants = draft.to.isEmpty || draft.from == draft.to ? [draft.from] : [draft.from, draft.to]
            let event = SequenceDiagram.Event.note(participants: participants, label: label)
            if let index { return .replaceEvent(index: index, with: event) }
            return .insertEvent(event, at: gap)
        case .activation:
            if let index {
                return .replaceActivation(index: index, participant: draft.from, end: max(index + 1, draft.end))
            }
            return .insertActivation(participant: draft.from, at: gap, end: max(gap, draft.end))
        case .fragment:
            if let index { return .replaceEvent(index: index, with: .beginBlock(kind: draft.block, label: label)) }
            return .insertFragment(kind: draft.block, label: label, at: gap)
        case .branch:
            if let index, case let .branch(kind, _) = diagram.events[index] {
                return .replaceEvent(index: index, with: .branch(kind: kind, label: label))
            }
            guard let branchFrame, let end = diagram.pairedEvent(for: branchFrame) else { return nil }
            return .insertBranch(in: branchFrame, at: end, label: label)
        }
    }

    private func commit(_ current: SequenceDraft) {
        guard canCommit(current), let edit = edit(for: current, at: insertionGap) else { return }
        apply(edit) { result in
            selection = result
            if let result {
                if let index = eventIndex(of: result) { scope = structure.scope(for: index) }
                reveal = SequenceReveal(selection: result)
            }
            placement = .append
            if current.target != nil {
                draft = result.flatMap(makeDraft(for:))
            } else if canAdd(current.tool) {
                var next = current
                next.session = UUID()
                next.label = ""
                next.end = -1
                defaults[current.tool] = next
                draft = next
                laneClick = .none
                labelFocused = current.tool != .activation
            } else {
                cancelDraft()
            }
        }
    }

    private func apply(_ edit: SequenceDiagram.Edit, completion: (SequenceSelection?) -> Void) {
        do {
            let result = try editor.editSequence(edit)
            diagram = try editor.sequenceDiagram
            appliedSource = editor.map.sequenceSource
            editError = nil
            completion(result)
        } catch {
            editError = error.localizedDescription
        }
    }

    private func adjacentGap(for target: SequenceSelection, direction: Int) -> Int? {
        switch target {
        case let .participant(id):
            guard let index = diagram.participants.firstIndex(where: { $0.id == id }),
                  diagram.participants.indices.contains(index + direction) else { return nil }
            return direction < 0 ? index - 1 : index + 2
        case let .event(index):
            return structure.siblingGap(for: index, direction: direction)
        }
    }

    private func move(_ target: SequenceSelection, to gap: Int) {
        let edit: SequenceDiagram.Edit = switch target {
        case let .participant(id): .moveParticipant(id: id, to: gap)
        case let .event(index): .moveEvent(index: index, to: gap)
        }
        apply(edit) { result in
            select(result, focus: false)
            if let result { reveal = SequenceReveal(selection: result) }
        }
    }

    private func delete(_ target: SequenceSelection) {
        let nextScope = eventIndex(of: target).map { structure.scope(at: $0) } ?? .root
        apply(.delete(target)) { _ in
            scope = structure.scopes.contains(nextScope) ? nextScope : .root
            selection = nil
            reveal = nil
            cancelDraft()
        }
    }

    private func eventIndex(of selection: SequenceSelection) -> Int? {
        if case let .event(index) = selection, diagram.events.indices.contains(index) { return index }
        return nil
    }

    private func matches(_ value: String) -> Bool {
        outlineQuery.isEmpty || value.localizedCaseInsensitiveContains(outlineQuery)
    }

    private func isOutlineRow(_ index: Int) -> Bool {
        switch diagram.events[index] {
        case .deactivate, .endBlock: return false
        default: return matches(structure.eventLabel(at: index))
        }
    }

    private func jump(to target: SequenceSelection) {
        showOutline = false
        select(target, focus: false)
        reveal = SequenceReveal(selection: target)
    }
}

enum SequenceTool: String, CaseIterable, Identifiable {
    case participant, message, note, activation, fragment, branch

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .participant: "参与者"
        case .message: "消息"
        case .note: "备注"
        case .activation: "激活"
        case .fragment: "片段"
        case .branch: "分支"
        }
    }

    var addTitle: LocalizedStringKey {
        switch self {
        case .participant: "添加参与者"
        case .message: "添加消息"
        case .note: "添加备注"
        case .activation: "添加激活"
        case .fragment: "添加片段"
        case .branch: "添加分支"
        }
    }

    var editTitle: LocalizedStringKey {
        switch self {
        case .participant: "编辑参与者"
        case .message: "编辑消息"
        case .note: "编辑备注"
        case .activation: "编辑激活"
        case .fragment: "编辑片段"
        case .branch: "编辑分支"
        }
    }

    var symbol: String {
        switch self {
        case .participant: "person.crop.rectangle"
        case .message: "arrow.right"
        case .note: "note.text"
        case .activation: "rectangle.portrait"
        case .fragment: "rectangle.dashed"
        case .branch: "line.3.horizontal.decrease"
        }
    }

    var canPlaceRelative: Bool {
        self == .message || self == .note || self == .activation || self == .fragment
    }
}

struct SequenceDraft {
    static let blockKinds: [SequenceDiagram.BlockKind] = [.loop, .opt, .alt, .par]

    let tool: SequenceTool
    var session = UUID()
    var target: SequenceSelection?
    var label = ""
    var from = ""
    var to = ""
    var arrow = SequenceDiagram.MessageKind.synchronous
    var block = SequenceDiagram.BlockKind.loop
    var end = -1

    func bound(to active: Binding<SequenceDraft?>) -> Binding<SequenceDraft> {
        // A native picker can read its binding while SwiftUI removes its form.
        // Keep that read valid and ignore writes from an expired editing session.
        Binding(
            get: {
                guard let draft = active.wrappedValue, draft.session == session else { return self }
                return draft
            },
            set: { value in
                guard active.wrappedValue?.session == session else { return }
                active.wrappedValue = value
            }
        )
    }
}

private enum SequencePlacement: CaseIterable {
    case append, before, after

    var title: LocalizedStringKey {
        switch self {
        case .append: "当前范围末尾"
        case .before: "所选元素之前"
        case .after: "所选元素之后"
        }
    }
}

private enum SequenceLaneClick {
    case none, from, to
}

private extension SequenceDiagram.MessageKind {
    var uiTitle: LocalizedStringKey {
        switch self {
        case .synchronous: "同步消息"
        case .asynchronous: "异步消息"
        case .reply: "返回消息"
        }
    }
}

private extension SequenceDiagram.BlockKind {
    var uiTitle: LocalizedStringKey {
        switch self {
        case .loop: "循环 (loop)"
        case .opt: "可选 (opt)"
        case .alt: "条件 (alt)"
        case .par: "并行 (par)"
        }
    }
}
