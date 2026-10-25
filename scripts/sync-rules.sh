#!/bin/zsh
# Regenerates Sources/UppdateraCore/BuiltInRules.swift from rules/rules.json, the file people edit.
# The built-in copy is what Uppdatera uses before it has downloaded the community rules.
set -euo pipefail
cd "${0:A:h}/.."
python3 -I - rules/rules.json Sources/UppdateraCore/BuiltInRules.swift <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
doc = json.load(open(src))
text = json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False)
assert '"""#' not in text
indented = "\n".join("    " + line for line in text.splitlines())
open(dst, "w").write(f'''import Foundation

// Generated from rules/rules.json by scripts/sync-rules.sh. Edit that file, not this one.
extension RulesStore {{
    static let builtInJSON = #"""
{indented}
    """#
}}
''')
print(f"{len(doc['apps'])} rules written to {dst}")
PY
