#!/bin/bash
# Ask the running Totum Commander what its panels show — the same road Claude takes.
# Nothing is changed: every command this bridge knows only reads.
BRIDGE="$(cd "$(dirname "$0")/.." && pwd)/Totum Commander.app/Contents/Helpers/fcxl-mcp"
[ -x "$BRIDGE" ] || { echo "Мост не собран: $BRIDGE"; exit 1; }

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"totum_panels","arguments":{}}}' \
| "$BRIDGE" | python3 -c '
import sys, json
for line in sys.stdin:
    d = json.loads(line); r = d.get("result", {})
    if "serverInfo" in r:
        print("Связь с мостом: есть")
    elif "tools" in r:
        print("Инструменты:", ", ".join(t["name"] for t in r["tools"]))
    elif "content" in r:
        print("\nЧто программа отвечает про свои панели:\n")
        print(r["content"][0]["text"])
'
