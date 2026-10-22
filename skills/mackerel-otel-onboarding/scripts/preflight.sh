#!/usr/bin/env bash
# フェーズ 0: 前提確認。ツール、compose、API キーの有効性を確認して組織名を表示する
# 使い方: scripts/preflight.sh [--compose-file FILE]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

COMPOSE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) COMPOSE_ARGS+=(-f "$2"); shift 2 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done

ok=true
log_info "必要なコマンドを確認します"
for c in docker curl jq; do
  if command -v "$c" >/dev/null 2>&1; then log_ok "$c: $(command -v "$c")"; else log_err "$c が見つかりません"; ok=false; fi
done
if docker compose version >/dev/null 2>&1; then
  log_ok "docker compose: $(docker compose version --short 2>/dev/null || echo '?')"
else
  log_err "docker compose (v2) が使えません"; ok=false
fi
if docker info >/dev/null 2>&1; then log_ok "Docker デーモンに接続できます"; else log_err "Docker デーモンに接続できません（起動していますか？）"; ok=false; fi

log_info "compose ファイルを確認します"
if docker compose "${COMPOSE_ARGS[@]}" config --quiet 2>/dev/null; then
  n="$(docker compose "${COMPOSE_ARGS[@]}" config --format json | jq '.services | length')"
  log_ok "compose は有効です（サービス数: ${n}、プロジェクト: $(docker compose "${COMPOSE_ARGS[@]}" config --format json | jq -r .name)）"
else
  log_err "カレントディレクトリに有効な compose ファイルがありません（docker compose config が失敗）"; ok=false
fi

log_info "Mackerel API キーを確認します（値は表示しません）"
load_api_key
if org="$(mkr_api GET /api/v0/org)"; then
  org_name="$(jq -r '.name' <<< "$org")"
  log_ok "API キーは有効です。組織: ${org_name}"
  # Write 権限の確認: 監視ルール一覧（Read）に加えて、ダッシュボード一覧（Read）だけでは判定できないため案内に留める
  log_info "Write 権限がない場合はダッシュボード・監視ルールの作成時に 403 になります"
  echo
  echo "organization: ${org_name}"
  echo "web: ${MACKEREL_WEB_BASE}/orgs/${org_name}"
else
  ok=false
fi

$ok || die "前提確認に失敗しました。上のメッセージを解消してから再実行してください"
log_ok "前提確認 OK"
