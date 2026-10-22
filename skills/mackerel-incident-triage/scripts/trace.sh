#!/usr/bin/env bash
# トレース 1 件の要約: サービス別のウォーターフォール、event、失敗属性、検出パターン、同じ traceId のログ
# 使い方: scripts/trace.sh TRACE_ID [--namespace NS] [--logs] [--json]
#   標準出力: 既定は人が読むウォーターフォール、--json なら JSON
#     {trace_id, url, root{service,name,start,duration_ms,status}, services[], spans[]（span_id 付き）, findings[]（url は該当 span を選択したトレース詳細）, business_keys{}, logs[]（--logs）}
#   --logs は、トレースに登場する各サービスのログをトレースの時間窓（前後 5〜10 秒）で取り、traceId が一致する行だけ返す
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

TRACE_ID=""; NAMESPACE=""; WITH_LOGS=false; JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --logs) WITH_LOGS=true; shift ;;
    --json) JSON=true; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    -*) die "不明な引数: $1" ;;
    *) TRACE_ID="$1"; shift ;;
  esac
done
[[ -n "$TRACE_ID" ]] || die "TRACE_ID を指定してください"
[[ -z "$NAMESPACE" ]] && NAMESPACE="${OTEL_SERVICE_NAMESPACE:-}"
load_api_key

raw="$(mkr_api GET "/api/v0/traces/${TRACE_ID}")" || die "トレース ${TRACE_ID} を取得できません"
ensure_org || die "組織名を取得できません"
web="$(mkr_web)"

# span を平坦化し、親子関係から深さを付け、パターンを検出する
summary="$(jq --arg tid "$TRACE_ID" --arg web "$web" "${JQ_LIB}"'
  def host_of: (. // "") | (capture("^[a-z]+://(?<h>[^/:]+)") // {h: ""}).h;
  (.spans | map({
      span_id: .spanId, parent_id: (.parentSpanId // ""), name, kind: (.kind // "internal"),
      service: ((.resource.attributes // []) | attrs | .["service.name"] // "?"),
      status: (.status.code // "unset"), status_message: (.status.message // ""),
      start_ms: (.startTime | ms), end_ms: (.endTime | ms),
      attrs: (.attributes | attrs),
      events: ((.events // []) | map({name, t_ms: (.time | ms)}))
    }) | map(. + {duration_ms: (.end_ms - .start_ms)})) as $spans
  | ($spans | map({(.span_id): .parent_id}) | add // {}) as $parent
  | ($spans | map(.span_id)) as $ids
  | def depth($id; $n): if $n > 50 then $n else (($parent[$id] // "") as $p | if $p == "" or ($ids | index($p)) == null then $n else depth($p; $n + 1) end) end;
    ($spans | map(. + {depth: depth(.span_id; 0)})) as $spans
  | ($spans | map(select(.depth == 0)) | sort_by(.start_ms) | .[0]) as $root
  | ($root.start_ms) as $t0
  | ($spans | map(. + {
        offset_ms: (.start_ms - $t0),
        http_status: (.attrs["http.response.status_code"] // null),
        target: (if .kind == "client" then (.attrs["url.full"] | host_of) else null end),
        # 失敗理由: アプリが付けた <domain>.failure_reason を優先し、無ければ error.type
        failure_reason: ((([.attrs | to_entries[] | select(.key | test("failure_reason$"))] | .[0].value) // .attrs["error.type"]) // null)
      }) | sort_by(.start_ms, .depth)) as $spans
  # パターン 1: 呼び出し側の client span が error なのに、呼ばれた側の server span は error でない（タイムアウトの不一致）
  | def method_of: (. // "") | ascii_upcase | (capture("(?<m>GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)") // {m: ""}).m;
    ([ $spans[] | select(.kind == "client" and .status == "error" and .http_status == null) as $c
      | ($c.name | method_of) as $cm
      | ($spans | map(select(.kind == "server" and .service != $c.service and .status != "error"
                               and .start_ms >= ($c.start_ms - 50) and .start_ms <= $c.end_ms
                               and ($c.target == "" or $c.target == null or .service == $c.target)
                               and ($cm == "" or (.name | method_of) == $cm)))
          | sort_by(-([.end_ms, $c.end_ms] | min) + .start_ms) | .[0]) as $s
      | select($s != null)
      | { type: "client_error_server_ok", from: $c.service, to: $s.service, route: $s.name, span_id: $c.span_id, url: ($web + "/traces/" + $tid + "?spanId=" + $c.span_id),
          client_ms: $c.duration_ms, server_ms: $s.duration_ms, server_http_status: $s.http_status,
          server_finished_after_client: ($s.end_ms > $c.end_ms), client_status_message: $c.status_message,
          client_error_type: ($c.attrs["error.type"] // null),
          detail: ("\($c.service) → \($s.service) \($s.name): 呼び出し側は \($c.duration_ms) ms で応答を受け取れず error" + (if (($c.status_message + " " + ($c.attrs["error.type"] // "")) | test("deadline|timeout|timed out|canceled"; "i")) then "（タイムアウト）" else "" end) + "、呼ばれた側は \($s.duration_ms) ms で正常終了（HTTP \($s.http_status // "?")）" + (if $s.end_ms > $c.end_ms then "。呼ばれた側の処理は呼び出し側が諦めた後に完了している" else "" end)) } ]) as $f1
  # パターン 2: 5xx を返した server span（最も深いものが起点の候補）
  | ([ $spans[] | select(.kind == "server" and (.http_status // 0) >= 500) ] | sort_by(-.depth)
      | map({ type: "server_5xx", service, route: .name, http_status, depth, duration_ms, failure_reason, span_id, url: ($web + "/traces/" + $tid + "?spanId=" + .span_id),
              detail: "\(.service) \(.name) が HTTP \(.http_status)" + (if .failure_reason then "（\(.failure_reason)）" else "" end) })) as $f2
  # パターン 3: DB クライアント span の error
  | ([ $spans[] | select(.kind == "client" and (.attrs["db.system.name"] // .attrs["db.system"] // null) != null and .status == "error")
      | { type: "db_error", service, operation: .name, db: (.attrs["db.system.name"] // .attrs["db.system"]), status_message, span_id, url: ($web + "/traces/" + $tid + "?spanId=" + .span_id), detail: "\(.service) の DB 操作 \(.name) が error: \(.status_message)" } ]) as $f3
  # パターン 4: 4xx の server span（業務上の拒否。情報として残す）
  | ([ $spans[] | select(.kind == "server" and (.http_status // 0) >= 400 and (.http_status // 0) < 500)
      | { type: "server_4xx", service, route: .name, http_status, failure_reason, detail: "\(.service) \(.name) が HTTP \(.http_status)" + (if .failure_reason then "（\(.failure_reason)）" else "" end) } ]) as $f4
  # 業務の識別子（order.id など）を全 span から集める
  | ([ $spans[] | .attrs | to_entries[] | select((.key | test("\\.(id|ref|key)$|_(id|ref)$")) or (.key | test("failure_reason|error\\.type"))) ]
      | map({(.key): .value}) | add // {}) as $keys
  | {
      trace_id: $tid,
      url: ($web + "/traces/" + $tid),
      root: { service: $root.service, name: $root.name, start: ($root.start_ms / 1000 | todate), start_ms: $root.start_ms, end_ms: ($spans | map(.end_ms) | max),
              duration_ms: $root.duration_ms, status: $root.status, http_status: $root.http_status },
      services: ($spans | map(.service) | unique),
      span_count: ($spans | length),
      spans: ($spans | map(select(.kind != "internal")) | map({span_id, service, name, kind, depth, offset_ms, duration_ms, status, http_status, target, failure_reason,
                                                               events: (.events | map({name, offset_ms: (.t_ms - $t0)}))})),
      findings: ($f1 + $f2 + $f3 + $f4),
      business_keys: $keys
    }' <<< "$raw")"

if $WITH_LOGS; then
  start_ms="$(jq '.root.start_ms' <<< "$summary")"; end_ms="$(jq '.root.end_ms' <<< "$summary")"
  from=$(( start_ms / 1000 - 5 )); to=$(( end_ms / 1000 + 10 ))
  logs="[]"
  while IFS= read -r svc; do
    [[ -z "$svc" || "$svc" == "?" ]] && continue
    body="$(jq -n --arg s "$svc" --arg ns "$NAMESPACE" --argjson f "$from" --argjson t "$to" '{serviceName:$s, serviceNamespace:$ns, from:$f, to:$t, perPage:100}')"
    if res="$(mkr_api POST /api/v0/logs "$body" 2>/dev/null)"; then
      logs="$(jq --argjson acc "$logs" --arg tid "$TRACE_ID" --arg svc "$svc" "${JQ_LIB}"'
        $acc + [ .results[] | select(.traceId == $tid)
                 | {timestamp, service: $svc, severity: (.severity // "UNKNOWN"), body: (.body | tostring),
                    attributes: (.attributes | attrs | with_entries(select(.value != null)))} ]' <<< "$res")"
    else
      log_warn "${svc} のログ検索に失敗しました（namespace='${NAMESPACE}' を確認）"
    fi
    sleep 1
  done < <(jq -r '.services[]' <<< "$summary")
  summary="$(jq --argjson logs "$logs" '. + {logs: ($logs | sort_by(.timestamp))}' <<< "$summary")"
fi

if $JSON; then jq . <<< "$summary"; exit 0; fi

# 人が読む形
jq -r '
  "trace \(.trace_id)  root: \(.root.service) \(.root.name)  \(.root.duration_ms) ms  status=\(.root.status) http=\(.root.http_status // "-")  start=\(.root.start)",
  "url: \(.url)",
  "services: \(.services | join(", "))   spans: \(.span_count)",
  (if (.business_keys | length) > 0 then "keys: \(.business_keys | to_entries | map("\(.key)=\(.value)") | join(" "))" else empty end),
  "",
  "  offset   dur     svc          kind    status  http  name",
  (.spans[] | "  \(.offset_ms | tostring | ("      " + .)[-6:])ms \(.duration_ms | tostring | ("      " + .)[-6:])ms \((.service + "            ")[0:12]) \((.kind + "       ")[0:7]) \((.status + "       ")[0:7]) \(((.http_status // "-") | tostring + "     ")[0:5]) \("  " * .depth)\(.name)\(if .failure_reason then "  ← \(.failure_reason)" else "" end)",
     (.events[] | "                                                                 \("  " * (.depth // 0))  · \(.name) @\(.offset_ms)ms")),
  "",
  (if (.findings | length) > 0 then ("findings:", (.findings[] | "  [\(.type)] \(.detail)")) else "findings: なし（status と HTTP は正常）" end),
  (if .logs then ("", "logs (同じ traceId):", (.logs[] | "  \(.timestamp) \((.service + "          ")[0:10]) \((.severity + "     ")[0:5]) \(.body)" + (if (.attributes | length) > 0 then "  \(.attributes | to_entries | map("\(.key)=\(.value)") | join(" "))" else "" end))) else empty end)
' <<< "$summary"
