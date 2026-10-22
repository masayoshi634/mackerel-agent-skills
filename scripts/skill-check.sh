#!/usr/bin/env bash
# skills/ 配下のスキルを検証する: frontmatter（Agent Skills 仕様）、references/scripts/assets への参照切れ、shellcheck、bash 構文、gofmt
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
for skill in skills/*/; do
  name="$(basename "$skill")"
  echo "== $name"
  python3 - "$skill/SKILL.md" "$name" << 'PY' || status=1
import sys, re
path, dirname = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n(.*)$", s, re.S)
assert m, "SKILL.md に frontmatter がありません"
fm, body = m.group(1), m.group(2)
name = re.search(r"^name:\s*(.+)$", fm, re.M); desc = re.search(r"^description:\s*(.+)$", fm, re.M)
assert name and desc, "name / description は必須です"
name, desc = name.group(1).strip(), desc.group(1).strip()
assert re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name) and len(name) <= 64, f"name が不正: {name}"
assert name == dirname, f"name ({name}) とディレクトリ名 ({dirname}) が一致しません"
assert len(desc) <= 1024, f"description が長すぎます: {len(desc)}"
lines = body.count("\n")
assert lines <= 500, f"SKILL.md 本文が 500 行を超えています: {lines}"
print(f"  frontmatter ok (description {len(desc)} chars, body {lines} lines)")
# SKILL.md と references/*.md から references/ scripts/ assets/ への参照（Markdown リンクとバッククォート内のパス）が存在するか
import os, glob
skill_dir = os.path.dirname(path)
# `${CLAUDE_SKILL_DIR}/scripts/x.sh` の形（プラグイン配布時に Claude Code が展開する）も、接頭辞を外して検査する
pat = re.compile(r"(?:\(|`)(?:\$\{CLAUDE_SKILL_DIR\}/)?((?:references|scripts|assets)/[^)\s`]+)(?:\)|`|\s)")
n = 0
for f in [path] + sorted(glob.glob(os.path.join(skill_dir, "references", "*.md"))):
    for ref in pat.findall(open(f, encoding="utf-8").read()):
        if "*" in ref or "..." in ref: continue   # パターン表記（scripts/*.sh、scripts/...）は検査しない
        assert os.path.exists(os.path.join(skill_dir, ref)), f"参照先がありません: {os.path.relpath(f, skill_dir)} → {ref}"
        n += 1
print(f"  references ok ({n} paths)")
PY
  if ls "$skill"/scripts/*.sh >/dev/null 2>&1; then
    bash -n "$skill"/scripts/*.sh && echo "  bash -n ok"
    if command -v shellcheck >/dev/null; then shellcheck -x -P "$skill/scripts" "$skill"/scripts/*.sh && echo "  shellcheck ok" || status=1; fi
  fi
  if ls "$skill"/assets/go/*.go >/dev/null 2>&1 && command -v gofmt >/dev/null; then
    out="$(gofmt -l "$skill"/assets/go)"; if [[ -n "$out" ]]; then echo "  gofmt NG: $out"; status=1; else echo "  gofmt ok"; fi
  fi
done

# プラグイン: plugins/<name>/.claude-plugin/plugin.json の name がディレクトリ名と一致し、version が SKILL.md の metadata.version と一致し、
# skills/<name> の symlink が実在すること。marketplace.json の各 source が存在すること
echo "== plugins"
python3 - << 'PLUGIN_PY' || status=1
import json, os, re
mp = json.load(open(".claude-plugin/marketplace.json", encoding="utf-8"))
assert mp.get("name") and mp.get("owner", {}).get("name") and mp.get("plugins"), "marketplace.json に name / owner.name / plugins が必要"
for entry in mp["plugins"]:
    src = entry["source"]
    assert src.startswith("./") and os.path.isdir(src), f"marketplace の source が無い: {src}"
    pj_path = os.path.join(src, ".claude-plugin", "plugin.json")
    pj = json.load(open(pj_path, encoding="utf-8"))
    assert pj["name"] == entry["name"] == os.path.basename(src.rstrip("/")), f"plugin の name が一致しない: {pj_path}"
    assert "version" not in entry, f"version は plugin.json だけに書く: {entry['name']}"
    skill_dir = os.path.join(src, "skills", pj["name"])
    assert os.path.islink(skill_dir) and os.path.isfile(os.path.join(skill_dir, "SKILL.md")), f"skills/{pj['name']} の symlink が無いか壊れている: {skill_dir}"
    fm = open(os.path.join(skill_dir, "SKILL.md"), encoding="utf-8").read().split("---")[1]
    m = re.search(r'^\s*version:\s*"?([^"\n]+)"?', fm, re.M)
    assert m and m.group(1).strip() == pj.get("version"), f"plugin.json の version ({pj.get('version')}) と SKILL.md の metadata.version ({m.group(1) if m else None}) が一致しない: {pj['name']}"
    print(f"  {pj['name']} {pj['version']} ok")
PLUGIN_PY
if command -v claude >/dev/null; then
  for p in . plugins/*/; do
    if claude plugin validate "$p" >/dev/null 2>&1; then echo "  claude plugin validate ok: $p"; else echo "  claude plugin validate NG: $p"; claude plugin validate "$p" 2>&1 | tail -5; status=1; fi
  done
else
  echo "  skip: claude CLI が無いので plugin validate を省略"
fi
exit $status
