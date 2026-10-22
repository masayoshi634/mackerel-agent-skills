#!/usr/bin/env bash
# 共通ライブラリ: ログ、前提チェック、Mackerel API 呼び出し（mackerel-otel-onboarding の lib.sh と同じ + 調査用ヘルパー）
# 使い方: source "$(dirname "$0")/lib.sh"
#
# 不変条件:
#   - API キーは環境変数 MACKEREL_APIKEY から読む（なければカレントの .env の MACKEREL_APIKEY= 行だけを読む。.env は実行しない）
#   - キーを標準出力・標準エラー・ファイルに書かない
#   - Mackerel に書き込まない（GET と検索の POST だけ）。リポジトリのファイルも変更しない

set -euo pipefail

MACKEREL_API_BASE="${MACKEREL_API_BASE:-https://api.mackerelio.com}"
MACKEREL_WEB_BASE="${MACKEREL_WEB_BASE:-https://mackerel.io}"

if [[ -t 2 ]]; then
  _c_info=$'\e[36m'; _c_ok=$'\e[32m'; _c_warn=$'\e[33m'; _c_err=$'\e[31m'; _c_off=$'\e[0m'
else
  _c_info=""; _c_ok=""; _c_warn=""; _c_err=""; _c_off=""
fi
log_info() { printf '%s[info]%s %s\n' "$_c_info" "$_c_off" "$*" >&2; }
log_ok()   { printf '%s[ ok ]%s %s\n' "$_c_ok" "$_c_off" "$*" >&2; }
log_warn() { printf '%s[warn]%s %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
log_err()  { printf '%s[fail]%s %s\n' "$_c_err" "$_c_off" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if (( ${#missing[@]} )); then
    die "必要なコマンドがありません: ${missing[*]}"
  fi
}

# MACKEREL_APIKEY を環境変数から読む。なければカレントディレクトリの .env から MACKEREL_APIKEY= の行だけを読む（値は出力しない）。
# .env は source しない: 対象リポジトリの .env に書かれた任意のコマンドや変数（MACKEREL_API_BASE の差し替え等）を評価しないため
load_api_key() {
  if [[ -z "${MACKEREL_APIKEY:-}" && -f .env ]]; then
    local line
    line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?MACKEREL_APIKEY=' .env 2>/dev/null | tail -1 || true)"
    if [[ -n "$line" ]]; then
      line="${line#*=}"
      line="$(printf '%s' "$line" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+$//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/")"
      MACKEREL_APIKEY="$line"; export MACKEREL_APIKEY
    fi
  fi
  if [[ -z "${MACKEREL_APIKEY:-}" ]]; then
    die "MACKEREL_APIKEY が設定されていません。Mackerel の [API キー] から Read 権限のキーを発行し、\`export MACKEREL_APIKEY=...\`（または .env に記載）してから再実行してください"
  fi
  # キーを送る先は Mackerel 本体だけに限定する。ホスト部だけを許し、パス・クエリ・ユーザー情報・ポートは認めない
  # （グロブの * は / や @ も含むので使わない）
  if ! [[ "$MACKEREL_API_BASE" =~ ^https://([a-z0-9-]+\.)+mackerelio\.com$ ]]; then
    die "MACKEREL_API_BASE は https://<host>.mackerelio.com の形だけ指定できます: ${MACKEREL_API_BASE}"
  fi
}

# mkr_api METHOD PATH [JSON_BODY]
#   成功: レスポンス本文を標準出力に出して 0 を返す
#   失敗: エラーを標準エラーに出して 1 を返す（5xx / 429 と接続エラーは 3 回までリトライ）
mkr_api() {
  local method="$1" path="$2" body="${3:-}"
  local attempt resp code out
  for attempt in 1 2 3; do
    # DELETE でも Content-Type: application/json がないと 400 になるので常に付ける
    local args=(-sS -w $'\n%{http_code}' --max-time 30 -H "X-Api-Key: ${MACKEREL_APIKEY}" -H "Content-Type: application/json" -X "$method" "${MACKEREL_API_BASE}${path}")
    [[ -n "$body" ]] && args+=(--data-binary "$body")
    if resp="$(curl "${args[@]}" 2>/dev/null)"; then
      code="${resp##*$'\n'}"; out="${resp%$'\n'*}"
      if [[ "$code" =~ ^2 ]]; then printf '%s' "$out"; return 0; fi
      if [[ "$code" =~ ^5 || "$code" == "429" ]]; then
        if [[ "$code" == "429" ]] || grep -q "Rate limit" <<< "$out"; then
          log_warn "Mackerel API のレート制限に当たりました（${attempt}/3）。$((attempt * 15)) 秒待ちます"; sleep $((attempt * 15))
        else
          log_warn "Mackerel API ${method} ${path} が HTTP ${code}（${attempt}/3）"; sleep $((attempt * 2))
        fi
        continue
      fi
      log_err "Mackerel API ${method} ${path} が HTTP ${code}: $(printf '%s' "$out" | head -c 300)"
      [[ "$code" == "401" || "$code" == "403" ]] && log_err "API キーか組織を確認してください（このスキルは Read 権限で動きます）"
      return 1
    fi
    log_warn "Mackerel API に接続できません（${attempt}/3）"; sleep $((attempt * 2))
  done
  log_err "Mackerel API ${method} ${path} に失敗しました"
  return 1
}

# 組織名を解決してキャッシュする（$(...) の中で呼ぶとキャッシュが親に残らないので、直接呼ぶ）。
# MACKEREL_ORG が環境変数にあれば API を叩かない（triage.sh が子スクリプトに渡す）
ensure_org() {
  [[ -n "${_MKR_ORG:-}" ]] && return 0
  if [[ -n "${MACKEREL_ORG:-}" ]]; then _MKR_ORG="$MACKEREL_ORG"; return 0; fi
  _MKR_ORG="$(mkr_api GET /api/v0/org | jq -r '.name')" || return 1
  export MACKEREL_ORG="$_MKR_ORG"
}
# 組織名を返す
mackerel_org_name() { ensure_org || return 1; printf '%s' "$_MKR_ORG"; }

# Mackerel 画面の URL（実機で確認した形式。2026-10）。先に ensure_org を呼んでおく
mkr_web() { printf '%s/orgs/%s' "$MACKEREL_WEB_BASE" "${_MKR_ORG:?ensure_org を先に呼ぶ}"; }
url_alert() { printf '%s/alerts/%s' "$(mkr_web)" "$1"; }                       # アラート詳細
url_monitor() { printf '%s/monitors/%s' "$(mkr_web)" "$1"; }                   # 監視ルール詳細
url_dashboard() { printf '%s/dashboards/%s#period=30m' "$(mkr_web)" "$1"; }    # ダッシュボード（urlPath）
url_apm_traces() {  # svc ns [traceId]: APM のサービスのトレース一覧（traceId を付けるとそのトレースに絞る）
  local u; u="$(mkr_web)/traces?service=$1&serviceNamespace=$2"; [[ -n "${3:-}" ]] && u+="&traceId=$3"; printf '%s#period=30m' "$u"; }
url_trace() {  # traceId [spanId]: トレース詳細（spanId で該当 span を選択）
  local u; u="$(mkr_web)/traces/$1"; [[ -n "${2:-}" ]] && u+="?spanId=$2"; printf '%s' "$u"; }
url_logs() {  # svc ns from_epoch to_epoch [traceId]: ログ検索（全 severity、traceId で絞れる）
  local u; u="$(mkr_web)/logs/search?service=$1&serviceNamespace=$2&timezone=Local&severities=DEBUG,ERROR,FATAL,INFO,TRACE,WARN"
  [[ -n "${5:-}" ]] && u+="&filterTraceId=$5"; printf '%s#t=%s,%s' "$u" "$(iso "$3")" "$(iso "$4")"; }

# JSON 文字列として安全にエスケープ
json_str() { jq -Rn --arg v "$1" '$v'; }

# compose のプロジェクト名（ディレクトリ名）
compose_project_name() {
  docker compose config --format json 2>/dev/null | jq -r '.name // empty' || true
}

# カンマ区切りを 1 行 1 要素に
split_csv() { tr ',' '\n' <<< "$1" | sed '/^\s*$/d'; }

# compose の OTEL_RESOURCE_ATTRIBUTES から service.namespace を推定する（なければ空）
detect_service_namespace() {
  docker compose config --format json 2>/dev/null \
    | jq -r '[.services[].environment.OTEL_RESOURCE_ATTRIBUTES // empty][0] // ""' \
    | tr ',' '\n' | sed -n 's/^service\.namespace=//p' | head -1
}

# ---- 調査用ヘルパー ----

# Mackerel API の応答で使う jq 関数。jq "$JQ_LIB"'<本体>' のように先頭に連結して使う
#   attrval: {valueType, stringValue|intValue|...} → 値
#   attrs:   [{key, value}] → {key: 値}
#   ms:      RFC 3339（小数秒あり/なし）→ エポックミリ秒
# shellcheck disable=SC2016,SC2034
JQ_LIB='
def attrval: if . == null then null else (.stringValue // .intValue // .doubleValue // .boolValue // .arrayValue // null) end;
def attrs: (. // []) | map({(.key): (.value | attrval)}) | add // {};
def ms: (sub("\\.[0-9]+Z$"; "Z") | fromdate) * 1000 + (((capture("\\.(?<f>[0-9]+)Z$") // {f:"0"}).f + "000")[0:3] | tonumber);
'

# 時間窓 [from, to]（エポック秒）を決める。--at があればその前後、なければ今から window 分前まで。
# トレース検索・APM 統計・ログ検索は 30 分を超えると 400 になるので上限を 30 分に丸める
window_bounds() { # window_min at_epoch(空可) → "from to"
  local win="$1" at="${2:-}" now from to
  (( win > 30 )) && { log_warn "時間窓は最大 30 分です（${win} → 30）"; win=30; }
  now=$(date +%s)
  if [[ -n "$at" ]]; then
    from=$(( at - win * 60 * 2 / 3 )); to=$(( at + win * 60 / 3 ))
    (( to > now )) && to=$now
  else
    to=$now; from=$(( now - win * 60 ))
  fi
  printf '%s %s' "$from" "$to"
}

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# 監視ルールの PromQL から service.name を取り出す（無ければ空）
service_from_query() { grep -oE 'service\.name="[^"]+"' <<< "$1" | head -1 | sed -E 's/.*="([^"]+)"/\1/' || true; }
# 監視ルールの PromQL からメトリクス名を取り出す（ラベル名 service.name= などは除く: 名前の直後が = ! ~ ならラベル）
metric_from_query() { grep -oE '[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+[^a-zA-Z0-9_.=!~]' <<< "$1 " | head -1 | sed -E 's/.$//' || true; }
