#!/usr/bin/env bash
# フェーズ 2: メトリクスの推移。ホストメトリックまたはサービスメトリックの値を取り、アラート発生の前後で比較する
# 使い方: scripts/metrics.sh (--host HOST_ID | --service NAME) --name METRIC [--window 60] [--at EPOCH] [--json]
#   --at はアラートの発生時刻（epoch）。指定すると窓の 2/3 を前、1/3 を後に取り、前後の平均を比べる
#   OpenTelemetry のラベル付きメトリクス（query 監視の対象）には取得 API が無い。アラートの value と APM 統計（triage.sh）を使う
#   出力: 標準エラーに直近の値の表と前後比較、標準出力に要約 JSON
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

HOST=""; SERVICE=""; NAME=""; WINDOW=60; AT=""; JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --at) AT="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ -n "$HOST" || -n "$SERVICE" ]] || die "--host か --service を指定してください"
[[ -n "$HOST" && -n "$SERVICE" ]] && die "--host と --service は同時に指定できません"
[[ -n "$NAME" ]] || die "--name でメトリック名を指定してください"
load_api_key

# 窓: ホスト・サービスメトリックには 30 分の制限が無いので window_bounds は使わず自前で計算する
now=$(date +%s)
if [[ -n "$AT" ]]; then
  FROM=$(( AT - WINDOW * 60 * 2 / 3 )); TO=$(( AT + WINDOW * 60 / 3 )); (( TO > now )) && TO=$now
else
  FROM=$(( now - WINDOW * 60 )); TO=$now
fi

if [[ -n "$HOST" ]]; then
  path="/api/v0/hosts/${HOST}/metrics"; target="host:${HOST}"
else
  path="/api/v0/services/${SERVICE}/metrics"; target="service:${SERVICE}"
fi
res="$(mkr_api GET "${path}?name=${NAME}&from=${FROM}&to=${TO}")" || die "メトリクスを取得できません（${target} ${NAME}。ホスト ID / サービス名とメトリック名を確認）"

summary="$(jq --arg target "$target" --arg name "$NAME" --argjson from "$FROM" --argjson to "$TO" --arg at "$AT" '
  (.metrics // []) as $m
  | ($m | map(.value)) as $v
  | ($at | if . == "" then null else tonumber end) as $at
  | def avg: if length == 0 then null else (add / length) end;
    {
      target: $target, name: $name, from: ($from | todate), to: ($to | todate), count: ($m | length),
      min: ($v | min), max: ($v | max), avg: ($v | avg),
      latest: ($m | last | if . then {time: (.time | todate), value} else null end),
      before_avg: (if $at then ($m | map(select(.time < $at)) | map(.value) | avg) else null end),
      after_avg: (if $at then ($m | map(select(.time >= $at)) | map(.value) | avg) else null end),
      points: ($m | map({time: (.time | todate), value}))
    }' <<< "$res")"

{
  printf '%s %s  窓 %s 〜 %s  件数 %s\n' "$target" "$NAME" "$(jq -r .from <<< "$summary")" "$(jq -r .to <<< "$summary")" "$(jq -r .count <<< "$summary")"
  jq -r '"  min \(.min // "-")  max \(.max // "-")  avg \(.avg // "-" | if type == "number" then (. * 100 | round / 100) else . end)  latest \(.latest.value // "-") (\(.latest.time // "-"))"' <<< "$summary"
  if [[ -n "$AT" ]]; then
    jq -r '"  発生前の平均 \(.before_avg // "-" | if type == "number" then (. * 100 | round / 100) else . end)  → 発生後の平均 \(.after_avg // "-" | if type == "number" then (. * 100 | round / 100) else . end)"' <<< "$summary"
  fi
  echo "  直近の値:"
  jq -r '.points[-10:][] | "    \(.time)  \(.value)"' <<< "$summary"
} >&2
if $JSON; then jq . <<< "$summary"; else jq 'del(.points)' <<< "$summary"; fi
