# Mindscape Agent examples

## Project plan

```bash
mindscape map create "Q4 规划" --template project
# use the returned map id and root id
mindscape node add <map> --parent <root> --text "目标"
mindscape node add <map> --parent <root> --text "里程碑"
mindscape node add <map> --parent <root> --text "风险"
mindscape map export <map> --format md --out ~/Downloads/q4-plan.md
```

## Meeting notes

```http
POST /v1/maps
{"title":"周会纪要","template":"meeting"}

POST /v1/maps/<id>/batch
{"operations":[
  {"op":"addNode","parentId":"<root>","text":"结论"},
  {"op":"addNode","parentId":"<root>","text":"待办"},
  {"op":"addNode","parentId":"<todo-node>","text":"负责人 / 截止时间"}
]}
```

## Read, edit, export

```bash
mindscape map list
mindscape map show <map>
mindscape node set <map> <node> --text "更新后的标题"
mindscape map export <map> --format pdf --out ~/Desktop/plan.pdf
```

## UML sequence diagram

```bash
mindscape map create "请求与响应" --template sequence
# use the returned document ID
mindscape map set-sequence <id> --file ./sequence.txt
mindscape map show <id>
mindscape map export <id> --format pdf --out ~/Downloads/sequence.pdf
mindscape map export <id> --format json --out ~/Downloads/sequence.json
```

`sequence.txt`:

```text
participant C as Client
participant S as Server
C->>S: Request
activate S
S-->>C: Response
deactivate S
```

## Failure handling

- `400 wrong_document_type`: use `sequenceSource` for UML sequence diagrams and node operations for tree maps.
- `400 invalid_sequence_source`: fix the reported source line or export the draft as JSON.
- `400 image_too_large`: lower the PNG scale or export PDF.
- `401`: read the gateway file again; the token may have rotated.
- `403`: the app is not accepting agent requests, or the request did not come from localhost.
- `409`: cycle/self-move or deleting the last remaining node.
- `413`: split the batch or shorten the text.
- `503`: gateway stopped; ask the user to enable it and retry once.
