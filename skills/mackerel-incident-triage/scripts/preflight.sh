#!/usr/bin/env bash
# フェーズ 0: 前提確認。curl / jq、API キーの有効性と組織名、開いているアラート数、gh（Issue 作成に使う。任意）を確認する
# 使い方: scripts/preflight.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '2,3p' "$0"; exit 0; }

ok=true
log_info "必要なコマンドを確認します"
for c in curl jq date; do
  if command -v "$c" >/dev/null 2>&1; then log_ok "$c: $(command -v "$c")"; else log_err "$c が見つかりません"; ok=false; fi
done
$ok || die "前提確認に失敗しました"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  log_ok "gh: 認証済み（フェーズ 6 の Issue 作成に使える）"
else
  log_warn "gh が無いか未認証。Issue は作れないので、報告は INCIDENT_<日付>.md にフォールバックする"
fi

log_info "Mackerel API キーを確認します（値は表示しません。Read 権限で足ります）"
load_api_key
org="$(mkr_api GET /api/v0/org)" || die "API キーが無効です"
org_name="$(jq -r '.name' <<< "$org")"
log_ok "API キーは有効です。組織: ${org_name}"
sleep 1
alerts="$(mkr_api GET /api/v0/alerts)" || die "アラート一覧を取得できません"
n_open="$(jq '.alerts | length' <<< "$alerts")"
log_ok "開いているアラート: ${n_open} 件"
echo
echo "organization: ${org_name}"
echo "alerts: ${MACKEREL_WEB_BASE}/orgs/${org_name}/alerts"
echo "open_alerts: ${n_open}"
log_ok "前提確認 OK"
