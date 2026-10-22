#!/usr/bin/env bash
# ログ検索: サービス × severity × 時間窓で Mackerel のログを取り、本文ごとに集計して traceId 付きで返す
# 使い方: scripts/logs.sh --service NAME [--namespace NS] [--window 30 | --from EPOCH --to EPOCH] [--at EPOCH]
#           [--severities ERROR,WARN] [--grep REGEX] [--trace-id ID] [--limit 100] [--raw]
#   標準出力: JSON {service, from, to, count, groups[]{body, severity, count, first, last, sample_attributes, trace_ids}, entries[]（--raw）}
#   --grep は本文と属性（JSON 文字列化）に対する正規表現、--trace-id は traceId の一致。どちらもクライアント側で絞る（API は未対応）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

SERVICE=""; NAMESPACE=""; WINDOW=30; FROM=""; TO=""; AT=""; SEVERITIES="ERROR,WARN"; GREP=""; TRACE_ID=""; LIMIT=100; RAW=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --at) AT="$2"; shift 2 ;;
    --severities) SEVERITIES="$2"; shift 2 ;;
    --grep) GREP="$2"; shift 2 ;;
    --trace-id) TRACE_ID="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --raw) RAW=true; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ -n "$SERVICE" ]] || die "--service は必須です"
[[ -z "$NAMESPACE" ]] && NAMESPACE="${OTEL_SERVICE_NAMESPACE:-}"
if [[ -z "$FROM" || -z "$TO" ]]; then read -r FROM TO <<< "$(window_bounds "$WINDOW" "$AT")"; fi
load_api_key

sev_json="$(split_csv "$SEVERITIES" | jq -R . | jq -sc .)"
body="$(jq -n --arg s "$SERVICE" --arg ns "$NAMESPACE" --argjson f "$FROM" --argjson t "$TO" --argjson pp "$LIMIT" --argjson sev "$sev_json" \
  '{serviceName:$s, serviceNamespace:$ns, from:$f, to:$t, perPage:$pp} + (if ($sev|length) > 0 and $sev != ["ALL"] then {severities:$sev} else {} end)')"
res="$(mkr_api POST /api/v0/logs "$body")" || die "ログ検索に失敗しました（service=${SERVICE}, namespace='${NAMESPACE}'）"

# shellcheck disable=SC2016
filter='
  [ .results[]
    | {timestamp, severity: (.severity // "UNKNOWN"), body: (.body | tostring), trace_id: (.traceId // null), span_id: (.spanId // null),
       attributes: (.attributes | attrs)}
    | select($tid == "" or .trace_id == $tid)
    | select($grep == "" or ((.body + " " + (.attributes | tojson)) | test($grep; "i")))
  ] as $entries
  | {
      service: $svc, from: ($from | todate), to: ($to | todate), count: ($entries | length),
      has_next_page: (.pagination.hasNextPage // false),
      groups: ($entries | group_by(.severity, .body)
        | map({ body: .[0].body, severity: .[0].severity, count: length,
                first: (map(.timestamp) | min), last: (map(.timestamp) | max),
                sample_attributes: (.[0].attributes | with_entries(select(.value != null)) | to_entries | .[0:8] | from_entries),
                trace_ids: ([.[].trace_id | select(. != null)] | unique | .[0:5]) })
        | sort_by(-.count))
    } + (if $raw then {entries: ($entries | sort_by(.timestamp))} else {} end)
'
jq --arg svc "$SERVICE" --argjson from "$FROM" --argjson to "$TO" --arg grep "$GREP" --arg tid "$TRACE_ID" --argjson raw "$RAW" \
  "${JQ_LIB}${filter}" <<< "$res"
