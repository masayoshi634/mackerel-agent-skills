#!/usr/bin/env bash
# フェーズ 4: 到達確認。各サービスのトレースが Mackerel の API で見えるまで待ち、APM 統計、Collector のエラー、Collector への depends_on を確認する
# 使い方: scripts/verify-ingest.sh [--services a,b,c] [--namespace NS] [--environment ENV] [--timeout 180] [--interval 15]
#           [--since-minutes 10] [--collector-service otel-collector] [--exclude-routes "/healthz"] [--hit URL]... [--logs]
#   出力の baseline はサービス単位の要約（5 分換算の件数、件数で重み付けしたエラー率、p95 の最大）。SLO のしきい値への翻訳（フェーズ 4.5）に使う
#   --logs を付けるとサービスごとのログ件数と traceId 付与率も確認する（Mackerel のログ機能を有効にした場合）
#   --hit を渡すと待つ前に各 URL を 3 回ずつ curl してトラフィックを作る
#   --namespace は OTEL_RESOURCE_ATTRIBUTES の service.namespace と一致させる（Mackerel API では必須）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq docker

SERVICES=""; NAMESPACE=""; ENVIRONMENT=""; TIMEOUT=180; INTERVAL=15; SINCE_MIN=10; COLLECTOR="otel-collector"; EXCLUDE=""; HITS=(); CHECK_LOGS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --services) SERVICES="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --since-minutes) SINCE_MIN="$2"; shift 2 ;;
    --collector-service) COLLECTOR="$2"; shift 2 ;;
    --exclude-routes) EXCLUDE="$2"; shift 2 ;;
    --hit) HITS+=("$2"); shift 2 ;;
    --logs) CHECK_LOGS=true; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done

inventory='{}'
if [[ -z "$SERVICES" || -z "$EXCLUDE" ]]; then
  inventory="$("$SCRIPT_DIR/discover.sh" 2>/dev/null || echo '{}')"  # compose 以外では失敗するが --services/--exclude-routes 指定で続行できる
fi
[[ -z "$SERVICES" ]] && SERVICES="$(jq -r '(.app_services // []) | join(",")' <<< "$inventory")"
[[ -z "$NAMESPACE" ]] && NAMESPACE="$(detect_service_namespace)"  # compose の OTEL_RESOURCE_ATTRIBUTES から
[[ -z "$EXCLUDE" ]] && EXCLUDE="$(inventory_exclude_routes "$inventory")"  # 要約からヘルスチェックのルートを除く
[[ -z "$EXCLUDE" ]] && EXCLUDE="/healthz"
exclude_json="$(split_csv "$EXCLUDE" | jq -R . | jq -sc .)"
[[ -z "$SERVICES" ]] && die "対象サービスがありません（--services で指定してください）"
load_api_key

if (( ${#HITS[@]} )); then
  log_info "トラフィックを作ります: ${HITS[*]}"
  for u in "${HITS[@]}"; do for _ in 1 2 3; do curl -sS -o /dev/null --max-time 10 "$u" || log_warn "GET $u に失敗"; done; done
fi

# トレース API / APM API は from〜to が 30 分以内でないと 400。レート制限も厳しいのでポーリングは控えめにする
if (( SINCE_MIN > 30 )); then log_warn "--since-minutes は最大 30（API の制限）。30 に丸めます"; SINCE_MIN=30; fi
if (( INTERVAL < 10 )); then log_warn "--interval は 10 秒以上を推奨（レート制限）。10 にします"; INTERVAL=10; fi
err_file="$(mktemp)"; trap 'rm -f "$err_file"' EXIT
from=$(( $(date +%s) - SINCE_MIN * 60 ))
deadline=$(( SECONDS + TIMEOUT ))
declare -A found=()
mapfile -t svc_list < <(split_csv "$SERVICES")
log_info "Mackerel にトレースが届くのを待ちます（最大 ${TIMEOUT}s、namespace='${NAMESPACE}'）"
while :; do
  to=$(date +%s)
  pending=()
  for svc in "${svc_list[@]}"; do
    [[ -n "${found[$svc]:-}" ]] && continue
    body="$(jq -n --arg s "$svc" --arg ns "$NAMESPACE" --arg env "$ENVIRONMENT" --argjson from "$from" --argjson to "$to" \
      '{serviceName:$s, serviceNamespace:$ns, from:$from, to:$to, perPage:1, order:{column:"START_AT",direction:"DESC"}} + (if $env != "" then {environment:$env} else {} end)')"
    if res="$(mkr_api POST /api/v0/traces "$body" 2>"$err_file")" && [[ "$(jq '.results | length' <<< "$res")" -gt 0 ]]; then
      found[$svc]="$(jq -r '.results[0].traceId' <<< "$res")"
      log_ok "${svc}: トレース到達（例: ${found[$svc]}）"
    else
      pending+=("$svc")
      if [[ -s "$err_file" && -z "${api_error_shown:-}" ]]; then api_error_shown=1; log_warn "$(head -3 "$err_file")"; fi
    fi
    sleep 1  # サービスごとの連続呼び出しを少し空ける
  done
  (( ${#pending[@]} == 0 )) && break
  if (( SECONDS >= deadline )); then
    log_err "届いていないサービス: ${pending[*]}"
    break
  fi
  log_info "待機中... 未到達: ${pending[*]}（残り $((deadline - SECONDS))s）"
  sleep "$INTERVAL"
done

echo
log_info "APM の HTTP server 統計（直近 ${SINCE_MIN} 分、上位 3 ルート）とサービス単位の要約（除外: ${EXCLUDE}）"
stats="{}"; baseline="{}"
for svc in "${svc_list[@]}"; do
  to=$(date +%s)
  q="serviceName=${svc}&serviceNamespace=${NAMESPACE}&from=${from}&to=${to}&perPage=50&orderColumn=REQUEST_COUNT"
  [[ -n "$ENVIRONMENT" ]] && q="${q}&environment=${ENVIRONMENT}"
  if res="$(mkr_api GET "/api/v0/apm/http-server-stats?${q}" 2>/dev/null)"; then
    all="$(jq -c --argjson ex "$exclude_json" '[.results[]? | .route as $r | select(($ex | index($r)) == null) | {method, route, requestCount, errorRatePercentage, approxP95Millis}]' <<< "$res")"
    rows="$(jq -c '.[:3]' <<< "$all")"
    printf '  %-14s %s\n' "$svc" "$(jq -r 'map("\(.method) \(.route) n=\(.requestCount) err=\(.errorRatePercentage)% p95=\(.approxP95Millis|floor)ms") | join(" | ")' <<< "$rows")" >&2
    # サービス単位の要約。API は p95 までしか返さないので p99 の実測は無い（SLO の目安は p95 × 1.5 程度、references/slo.md）
    summary="$(jq -c --argjson win "$(( to - from ))" '
      (map(.requestCount) | add // 0) as $n
      | { requests_total: $n,
          requests_per_5m: (if $win > 0 then (($n * 300 / $win * 10 | round) / 10) else null end),
          error_rate_pct: (if $n > 0 then (((map(.requestCount * .errorRatePercentage) | add) / $n * 100 | round) / 100) else null end),
          p95_max_ms: ((map(.approxP95Millis) | max) as $m | if $m == null then null else ($m | floor) end),
          window_minutes: (($win / 60) | floor) }' <<< "$all")"
    printf '  %-14s 要約: %s\n' "" "$(jq -r '"n=\(.requests_total)（\(.requests_per_5m) 件/5分） err=\(.error_rate_pct)% p95max=\(.p95_max_ms)ms window=\(.window_minutes)分"' <<< "$summary")" >&2
    stats="$(jq --arg s "$svc" --argjson r "$rows" '. + {($s): $r}' <<< "$stats")"
    baseline="$(jq --arg s "$svc" --argjson b "$summary" '. + {($s): $b}' <<< "$baseline")"
  fi
done

logs_json="{}"
if $CHECK_LOGS; then
  echo
  log_info "ログの到達（直近 ${SINCE_MIN} 分）と traceId の付与率"
  for svc in "${svc_list[@]}"; do
    to=$(date +%s)
    body="$(jq -n --arg s "$svc" --arg ns "$NAMESPACE" --argjson from "$from" --argjson to "$to" '{serviceName:$s, serviceNamespace:$ns, from:$from, to:$to, perPage:100}')"
    if res="$(mkr_api POST /api/v0/logs "$body" 2>/dev/null)"; then
      n="$(jq '.results | length' <<< "$res")"; t="$(jq '[.results[] | select(.traceId != null)] | length' <<< "$res")"
      if (( n == 0 )); then printf '  %-14s なし（SDK のログブリッジが有効か、console.log ではないか確認）\n' "$svc" >&2
      else printf '  %-14s %s 件、traceId あり %s 件\n' "$svc" "$n" "$t" >&2; fi
      logs_json="$(jq --arg s "$svc" --argjson n "$n" --argjson t "$t" '. + {($s): {count:$n, with_trace_id:$t}}' <<< "$logs_json")"
    fi
    sleep 1
  done
fi

echo
log_info "各サービスの depends_on に Collector（${COLLECTOR}）があるか確認します"
# 無いと compose down で Collector が先に止まり、SDK の export エラーが Mackerel のログに残って停止も遅くなる
dep_missing=()
compose_json="$(docker compose config --format json 2>/dev/null || true)"
for svc in "${svc_list[@]}"; do
  if [[ -n "$compose_json" ]] && ! jq -e --arg s "$svc" --arg c "$COLLECTOR" '.services[$s].depends_on // {} | has($c)' <<< "$compose_json" >/dev/null; then
    dep_missing+=("$svc")
  fi
done
if (( ${#dep_missing[@]} )); then
  log_warn "depends_on に ${COLLECTOR} がないサービス: ${dep_missing[*]}"
  log_warn "  compose.yaml の各サービスに  depends_on: { ${COLLECTOR}: { condition: service_started } }  を追記してください（assets/compose.otel.snippet.yaml 参照）"
else
  log_ok "全サービスが ${COLLECTOR} に depends_on しています"
fi

echo
log_info "Collector（${COLLECTOR}）のログに export エラーがないか確認します"
collector_errors="$(docker compose logs --no-color --since "${SINCE_MIN}m" "$COLLECTOR" 2>/dev/null | grep -iE '"level":"error"|[[:space:]]error[[:space:]]|Exporting failed|Permanent error|HTTP 40[13]|not supported' | grep -v "Development component" | tail -5 || true)"
if [[ -n "$collector_errors" ]]; then
  log_warn "Collector にエラーがあります:"; sed -E 's/[A-Za-z0-9]{32,}/<redacted>/g' <<< "$collector_errors" >&2
else
  log_ok "Collector にエラーはありません"
fi

missing=()
for svc in "${svc_list[@]}"; do [[ -z "${found[$svc]:-}" ]] && missing+=("$svc"); done
jq -n --arg ns "$NAMESPACE" --argjson found "$(for s in "${!found[@]}"; do jq -n --arg k "$s" --arg v "${found[$s]}" '{($k):$v}'; done | jq -s 'add // {}')" \
  --argjson missing "$(printf '%s\n' "${missing[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" --argjson stats "$stats" \
  --arg collector_errors "$collector_errors" --argjson logs "$logs_json" --argjson baseline "$baseline" \
  --argjson dep_missing "$(printf '%s\n' "${dep_missing[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{namespace:$ns, traces_found:$found, traces_missing:$missing, apm_stats:$stats, baseline:$baseline, logs:$logs, collector_errors:($collector_errors != ""), collector_dependency_missing:$dep_missing, note:"メトリクスは PromQL クエリ API がないため API では確認できない。ダッシュボード作成後に画面で確認する（反映まで 1〜2 分）"}'
(( ${#missing[@]} == 0 ))
