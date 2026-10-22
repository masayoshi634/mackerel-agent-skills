#!/usr/bin/env bash
# 共通ライブラリ: ログ、前提チェック、Mackerel API 呼び出し
# 使い方: source "$(dirname "$0")/lib.sh"
#
# 不変条件:
#   - API キーは環境変数 MACKEREL_APIKEY から読む（なければカレントの .env の MACKEREL_APIKEY= 行だけを読む。.env は実行しない）
#   - キーを標準出力・標準エラー・ファイルに書かない
#   - リポジトリのファイルを変更しない

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
    die "MACKEREL_APIKEY が設定されていません。Mackerel の [API キー] から Write 権限のキーを発行し、\`export MACKEREL_APIKEY=...\`（または .env に記載）してから再実行してください"
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
      [[ "$code" == "401" || "$code" == "403" ]] && log_err "API キーの権限（Write）か組織を確認してください"
      return 1
    fi
    log_warn "Mackerel API に接続できません（${attempt}/3）"; sleep $((attempt * 2))
  done
  log_err "Mackerel API ${method} ${path} に失敗しました"
  return 1
}

# 組織名を返す（キャッシュ）
mackerel_org_name() {
  if [[ -z "${_MKR_ORG:-}" ]]; then
    _MKR_ORG="$(mkr_api GET /api/v0/org | jq -r '.name')" || return 1
  fi
  printf '%s' "$_MKR_ORG"
}

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

# 監視ルール名の接頭辞の既定。プロジェクト名を含め、同じ組織で複数のアプリに適用しても互いのルールを消し合わないようにする
default_prefix() { printf '[otel-onboarding:%s]' "$1"; }

# ダッシュボードの urlPath（プロジェクト名を URL に使える文字に丸める）
dashboard_url_path() { printf 'otel-onboarding-%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | sed 's/-*$//')"; }

# 除外ルート（カンマ区切り）を PromQL のラベルマッチャにする。1 つなら !=、複数なら !~ の選択肢
#   例: "/healthz" → http.route!="/healthz" / "/healthz,/readyz" → http.route!~"(/healthz|/readyz)"
route_exclusion() {
  local routes="$1" n
  n="$(split_csv "$routes" | wc -l)"
  if (( n == 0 )); then return 0; fi
  if (( n == 1 )); then printf 'http.route!="%s"' "$(split_csv "$routes")"; return 0; fi
  printf 'http.route!~"(%s)"' "$(split_csv "$routes" | sed 's/\./\\\\./g' | paste -sd'|' -)"
}

# inventory（discover.sh の出力）の exclude_routes をカンマ区切りで返す
inventory_exclude_routes() { jq -r '(.exclude_routes // []) | join(",")' <<< "$1"; }

# 監視ルールの memo から "SLO: ..." 行を取り出す（無ければ空）
memo_slo_line() { sed -n 's/^SLO: //p' <<< "$1" | head -1; }
