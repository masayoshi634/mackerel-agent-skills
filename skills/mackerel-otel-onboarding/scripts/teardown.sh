#!/usr/bin/env bash
# スキルが作った Mackerel 上のリソース（ダッシュボード・監視ルール）を削除する。コードや compose は触らない
# 使い方: scripts/teardown.sh [--project NAME] [--prefix "[otel-onboarding:<project>]"] [--monitors-only] [--yes]
#   v0.2 以前の接頭辞（プロジェクト名なし）で作ったルールだけを消すときは --prefix "[otel-onboarding]" --monitors-only を付ける
#   （--monitors-only が無いと、接頭辞に関係なくプロジェクトのダッシュボードも削除される）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

PROJECT=""; PREFIX=""; YES=false; MONITORS_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --monitors-only) MONITORS_ONLY=true; shift ;;
    --yes|-y) YES=true; shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ -z "$PROJECT" ]] && PROJECT="$(compose_project_name)"
[[ -z "$PROJECT" ]] && PROJECT="$(basename "$PWD")"
[[ -z "$PREFIX" ]] && PREFIX="$(default_prefix "$PROJECT")"
load_api_key
url_path="$(dashboard_url_path "$PROJECT")"

dash_ids=""
$MONITORS_ONLY || dash_ids="$(mkr_api GET /api/v0/dashboards | jq -r --arg u "$url_path" '.dashboards[] | select(.urlPath == $u) | .id')"
mon="$(mkr_api GET /api/v0/monitors | jq -c --arg p "$PREFIX" '[.monitors[] | select(.name | startswith($p)) | {id, name}]')"
n_dash="$(grep -c . <<< "${dash_ids}" || true)"; n_mon="$(jq 'length' <<< "$mon")"
log_info "削除対象: ダッシュボード ${n_dash} 件（urlPath=${url_path}$($MONITORS_ONLY && echo '、--monitors-only のため対象外')）、監視ルール ${n_mon} 件（接頭辞 '${PREFIX}'）"
jq -r '.[] | "  - \(.name)"' <<< "$mon" >&2
if (( n_dash == 0 && n_mon == 0 )); then log_ok "削除するものはありません"; exit 0; fi
if ! $YES; then
  read -r -p "削除しますか？ [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log_info "中止しました"; exit 0; }
fi
while IFS= read -r id; do [[ -n "$id" ]] && mkr_api DELETE "/api/v0/dashboards/${id}" >/dev/null && log_ok "dashboard ${id} を削除"; done <<< "$dash_ids"
while IFS= read -r id; do [[ -n "$id" ]] && mkr_api DELETE "/api/v0/monitors/${id}" >/dev/null && log_ok "monitor ${id} を削除"; done < <(jq -r '.[].id' <<< "$mon")
log_ok "完了"
