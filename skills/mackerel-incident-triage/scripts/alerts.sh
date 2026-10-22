#!/usr/bin/env bash
# フェーズ 1: アラート一覧。開いているアラートに監視ルール名・種別・しきい値・対象サービスと、種別ごとに辿れる範囲（scope）を付けて返す
# 使い方: scripts/alerts.sh [--prefix "[otel-onboarding]"] [--with-closed] [--limit 50]
#   標準出力: JSON（alerts[]: id, status, value, opened_at, age_min, host_id, url, monitor{..., url_web}, service, metric, scope）
#   scope: apm-traces-logs（query 監視） / host-metrics / service-metrics / external-url / check-host / expression / unknown
#   標準エラー: 人が読む表
#   --prefix を付けると、その接頭辞で始まる監視ルールのアラートだけに絞る（既定は全部）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

PREFIX=""; WITH_CLOSED=false; LIMIT=50
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --with-closed) WITH_CLOSED=true; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done
load_api_key

q="limit=${LIMIT}"; $WITH_CLOSED && q="${q}&withClosed=true"
alerts="$(mkr_api GET "/api/v0/alerts?${q}")" || die "アラート一覧を取得できません"
sleep 1
monitors="$(mkr_api GET /api/v0/monitors)" || die "監視ルール一覧を取得できません"
now=$(date +%s)
ensure_org || die "組織名を取得できません"
web="$(mkr_web)"

out="$(jq -n --argjson a "$alerts" --argjson m "$monitors" --argjson now "$now" --arg prefix "$PREFIX" --arg web "$web" '
  ($m.monitors | map({(.id): .}) | add // {}) as $byid
  | {
      fetched_at: ($now | todate),
      alerts: [ $a.alerts[]
        | . as $al
        | ($byid[$al.monitorId // ""] // null) as $mon
        | select($prefix == "" or (($mon.name // "") | startswith($prefix)))
        | {
            id: $al.id, status: $al.status, type: $al.type, value: $al.value,
            opened_at: ($al.openedAt | todate), age_min: ((($al.closedAt // $now) - $al.openedAt) / 60 | floor),
            closed_at: (if $al.closedAt then ($al.closedAt | todate) else null end),
            opened_epoch: $al.openedAt,
            host_id: ($al.hostId // null),
            url: ($web + "/alerts/" + $al.id),
            monitor: (if $mon then {id: $mon.id, name: $mon.name, type: $mon.type, query: ($mon.query // null), url: ($mon.url // null), url_web: ($web + "/monitors/" + $mon.id),
                                    metric: ($mon.metric // null), service: ($mon.service // null),
                                    operator: ($mon.operator // null), warning: ($mon.warning // null), critical: ($mon.critical // null), memo: ($mon.memo // null)}
                      else null end),
            # 対象サービス: query 監視は PromQL の service.name、サービスメトリック監視は監視ルールの service
            service: ((($mon.query // "") | (capture("service\\.name=\"(?<s>[^\"]+)\"") // {s: null}).s) // ($mon.service // null)),
            metric: ((($mon.query // "") | ([scan("[a-zA-Z_][a-zA-Z0-9_]*(?:\\.[a-zA-Z0-9_]+)+(?![a-zA-Z0-9_.=!~])")] | .[0] // null)) // ($mon.metric // null)),
            # 種別ごとに辿れる範囲（references/mackerel-api.md の表）
            scope: ({query: "apm-traces-logs", host: "host-metrics", service: "service-metrics", external: "external-url",
                     check: "check-host", connectivity: "check-host", expression: "expression", anomalyDetection: "host-metrics"}[$mon.type // ""] // "unknown")
          } ]
      | sort_by(.status != "CRITICAL", .status != "WARNING", .opened_epoch)
    }')"

{
  printf '%-8s %-8s %-8s %-5s %-10s %-46s %-12s %s\n' "STATUS" "TYPE" "AGE(min)" "VALUE" "SERVICE" "MONITOR" "ALERT_ID" "METRIC / SCOPE"
  jq -r '.alerts[] | [ .status, (.monitor.type // "-"), (.age_min|tostring), ((.value // "-") | tostring | .[0:5]), (.service // "-"), ((.monitor.name // "(monitor deleted)") | .[0:46]), .id, ((.metric // "-") + " [" + .scope + "]") ]
         | @tsv' <<< "$out" | awk -F'\t' '{ printf "%-8s %-8s %-8s %-5s %-10s %-46s %-12s %s\n", $1, $2, $3, $4, $5, $6, $7, $8 }'
  n="$(jq '.alerts | length' <<< "$out")"; echo "($n 件)"
} >&2
jq . <<< "$out"
