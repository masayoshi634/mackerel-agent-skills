#!/usr/bin/env bash
# フェーズ 3: 一次調査。アラート（または監視ルール・サービス）を起点に、APM 統計・ログ・トレースを集めて
#   症状の広がり、代表トレースの検出パターン、ログの集計を 1 つのレポートにまとめる。Mackerel には書き込まない
# 使い方: scripts/triage.sh (--alert ALERT_ID | --monitor "名前" | --service a[,b,c]) [--services a,b,c]
#           [--namespace NS] [--window 30] [--at EPOCH] [--traces 3] [--prefix "[otel-onboarding]"] [--out DIR] [--json]
#   --service で起点のサービス、--services で調査対象の全サービスを指定する（省略時は監視ルールの PromQL に出てくる service.name を全部）
#   --at は窓の中心時刻（過去の障害を調べるとき）。--window は最大 30 分
#   出力: 標準出力に Markdown（--json なら JSON）。--out DIR を付けると triage.json / triage.md / trace-<id>.json も保存する
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

ALERT=""; MONITOR=""; SERVICE=""; SERVICES=""; NAMESPACE=""; WINDOW=30; AT=""; NTRACES=3; PREFIX=""; OUT=""; JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --alert) ALERT="$2"; shift 2 ;;
    --monitor) MONITOR="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --services) SERVICES="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --at) AT="$2"; shift 2 ;;
    --traces) NTRACES="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ -n "$ALERT$MONITOR$SERVICE" ]] || die "--alert か --monitor か --service のどれかを指定してください"
[[ -z "$NAMESPACE" ]] && NAMESPACE="${OTEL_SERVICE_NAMESPACE:-}"
load_api_key
ensure_org || die "組織名を取得できません"   # 子スクリプト（trace.sh）には MACKEREL_ORG で渡る
web="$(mkr_web)"

# ---- 1. 起点の解決（アラート → 監視ルール → サービス）----
alert_json="null"; monitor_json="null"; focus_services=()
monitors="$(mkr_api GET /api/v0/monitors)" || die "監視ルール一覧を取得できません"
sleep 1
if [[ -n "$ALERT" ]]; then
  alerts="$(mkr_api GET "/api/v0/alerts?withClosed=true&limit=100")" || die "アラート一覧を取得できません"
  alert_json="$(jq -c --arg id "$ALERT" '[.alerts[] | select(.id == $id)] | .[0] // null' <<< "$alerts")"
  [[ "$alert_json" != "null" ]] || die "アラート ${ALERT} が見つかりません（直近 100 件に無い場合は --monitor か --service で指定）"
  mid="$(jq -r '.monitorId // empty' <<< "$alert_json")"
  monitor_json="$(jq -c --arg id "$mid" '[.monitors[] | select(.id == $id)] | .[0] // null' <<< "$monitors")"
  [[ -z "$AT" ]] && AT="$(jq -r '.openedAt' <<< "$alert_json")"
  sleep 1
elif [[ -n "$MONITOR" ]]; then
  monitor_json="$(jq -c --arg n "$MONITOR" '[.monitors[] | select(.name == $n)] | .[0] // null' <<< "$monitors")"
  [[ "$monitor_json" != "null" ]] || die "監視ルール '${MONITOR}' が見つかりません"
fi
if [[ "$monitor_json" != "null" ]]; then
  q="$(jq -r '.query // ""' <<< "$monitor_json")"
  svc="$(service_from_query "$q")"
  [[ -n "$svc" ]] && focus_services+=("$svc")
fi
[[ -n "$SERVICE" ]] && while IFS= read -r s; do focus_services+=("$s"); done < <(split_csv "$SERVICE")

# 調査対象の全サービス: --services > 監視ルールの PromQL から集めた service.name
if [[ -n "$SERVICES" ]]; then
  mapfile -t all_services < <(split_csv "$SERVICES")
else
  mapfile -t all_services < <(jq -r --arg p "$PREFIX" '.monitors[] | select($p == "" or (.name | startswith($p))) | .query // "" | capture("service\\.name=\"(?<s>[^\"]+)\"") | .s' <<< "$monitors" | sort -u)
fi
(( ${#all_services[@]} )) || die "調査対象のサービスが分かりません。--services a,b,c で指定してください"
# 起点が無く、監視ルールがカスタムメトリクス（service.name なし）なら、メトリクス名の区切り（shop.checkout.orphan_charges → checkout）から探す
if (( ${#focus_services[@]} == 0 )) && [[ "$monitor_json" != "null" ]]; then
  metric="$(metric_from_query "$(jq -r '.query // ""' <<< "$monitor_json")")"
  for tok in $(tr '._-' '   ' <<< "$metric"); do
    for s in "${all_services[@]}"; do [[ "$s" == "$tok" ]] && focus_services+=("$s"); done
  done
  (( ${#focus_services[@]} )) && log_info "メトリクス名 ${metric} から起点サービスを推定: ${focus_services[*]}"
fi
# それでも無ければ全サービスを起点にする
(( ${#focus_services[@]} )) || focus_services=("${all_services[@]}")

# ---- 2. 時間窓 ----
(( WINDOW > 30 )) && WINDOW=30
if [[ -n "$AT" ]]; then
  # アラートの発生時刻を中心に: 発生の 2/3 前から 1/3 後まで（今を超えない）
  read -r FROM TO <<< "$(window_bounds "$WINDOW" "$AT")"
else
  read -r FROM TO <<< "$(window_bounds "$WINDOW" "")"
fi
log_info "調査窓: $(iso "$FROM") 〜 $(iso "$TO")（namespace='${NAMESPACE}'、起点: ${focus_services[*]}、対象: ${all_services[*]}）"

# ---- 3. サービスごとに APM 統計とログを集める ----
services_json="[]"
for svc in "${all_services[@]}"; do
  q="serviceName=${svc}&serviceNamespace=${NAMESPACE}&from=${FROM}&to=${TO}&orderColumn=REQUEST_COUNT"
  stats="$(mkr_api GET "/api/v0/apm/http-server-stats?${q}" 2>/dev/null || echo '{"results":[]}')"
  sleep 1
  logs="$("$SCRIPT_DIR/logs.sh" --service "$svc" --namespace "$NAMESPACE" --from "$FROM" --to "$TO" --severities ERROR,WARN --limit 100 2>/dev/null || echo '{"count":0,"groups":[]}')"
  sleep 1
  services_json="$(jq --argjson acc "$services_json" --arg svc "$svc" --argjson stats "$stats" --argjson logs "$logs" -n '
    $acc + [{
      service: $svc,
      routes: ([$stats.results[]? | {method, route, requests: .requestCount, error_rate: .errorRatePercentage, p95_ms: .approxP95Millis}]),
      error_routes: ([$stats.results[]? | select(.errorRatePercentage > 0) | {method, route, requests: .requestCount, error_rate: .errorRatePercentage, p95_ms: .approxP95Millis}] | sort_by(-.error_rate)),
      slow_routes: ([$stats.results[]? | {method, route, requests: .requestCount, p95_ms: .approxP95Millis}] | sort_by(-.p95_ms) | .[0:3]),
      log_count: $logs.count,
      log_groups: ($logs.groups | map({body, severity, count, sample_attributes, trace_ids}))
    }]')"
done

# ---- 4. 代表トレース: 起点サービスの WARN/ERROR ログに付いた traceId（頻度順） + 遅い順の検索 ----
candidates=()
while IFS= read -r t; do [[ -n "$t" ]] && candidates+=("$t"); done < <(
  jq -r --argjson focus "$(printf '%s\n' "${focus_services[@]}" | jq -R . | jq -sc .)" '
    [ .[] | select(.service as $s | $focus | index($s)) | .log_groups[] | .trace_ids[] ] | unique | .[]' <<< "$services_json")
for svc in "${focus_services[@]}"; do
  body="$(jq -n --arg s "$svc" --arg ns "$NAMESPACE" --argjson f "$FROM" --argjson t "$TO" --argjson pp "$NTRACES" \
    '{serviceName:$s, serviceNamespace:$ns, from:$f, to:$t, perPage:$pp, order:{column:"LATENCY",direction:"DESC"}}')"
  if res="$(mkr_api POST /api/v0/traces "$body" 2>/dev/null)"; then
    while IFS= read -r t; do [[ -n "$t" ]] && candidates+=("$t"); done < <(jq -r '.results[].traceId' <<< "$res")
  fi
  sleep 1
done
mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++' | head -n "$NTRACES")

traces_json="[]"
for t in "${candidates[@]}"; do
  if tj="$("$SCRIPT_DIR/trace.sh" "$t" --namespace "$NAMESPACE" --logs --json 2>/dev/null)"; then
    traces_json="$(jq --argjson acc "$traces_json" --argjson t "$tj" -n '$acc + [$t]')"
    [[ -n "$OUT" ]] && { mkdir -p "$OUT"; jq . <<< "$tj" > "$OUT/trace-${t}.json"; }
  else
    log_warn "トレース ${t} を取得できませんでした"
  fi
  sleep 1
done

# ---- 5. まとめ（仮説は根拠付きで列挙。断定はエージェントと人に委ねる）----
report="$(jq -n --argjson alert "$alert_json" --argjson monitor "$monitor_json" --argjson services "$services_json" --argjson traces "$traces_json" \
  --arg ns "$NAMESPACE" --argjson from "$FROM" --argjson to "$TO" --argjson focus "$(printf '%s\n' "${focus_services[@]}" | jq -R . | jq -sc .)" --arg web "$web" '
  ($traces | map(.findings[]?) ) as $findings
  | ($findings | map(select(.type == "client_error_server_ok"))) as $mismatch
  | ($findings | map(select(.type == "server_5xx")) | group_by(.service + " " + .route) | map({service: .[0].service, route: .[0].route, http_status: .[0].http_status, failure_reason: (map(.failure_reason) | unique | map(select(. != null))), max_depth: (map(.depth) | max), n: length}) | sort_by(-.max_depth)) as $fivexx
  | ($findings | map(select(.type == "db_error"))) as $db
  | ($services | map(select(.log_count > 0)) | map({service, log_groups: (.log_groups | map({body, severity, count}))})) as $logsum
  | ($services | map(. as $s | .log_groups[] | select(.body | test("reconcile|inconsisten|orphan|drift|mismatch|stale"; "i")) | {service: $s.service, body, count, sample_attributes}) ) as $invariant_logs
  # 画面の URL（lib.sh の url_* と同じ形式）
  | ($web + "/logs/search?service=") as $logs_base
  | ("&serviceNamespace=" + $ns + "&timezone=Local&severities=DEBUG,ERROR,FATAL,INFO,TRACE,WARN") as $logs_q
  | ("#t=" + ($from | todate) + "," + ($to | todate)) as $logs_t
  | {
      generated_at: (now | todate), namespace: $ns, window: {from: ($from | todate), to: ($to | todate)},
      urls: {
        alert: (if $alert then $web + "/alerts/" + $alert.id else null end),
        monitor: (if $monitor then $web + "/monitors/" + $monitor.id else null end),
        apm: ($services | map({(.service): ($web + "/traces?service=" + .service + "&serviceNamespace=" + $ns + "#period=30m")}) | add // {}),
        logs: ($services | map({(.service): ($logs_base + .service + $logs_q + $logs_t)}) | add // {})
      },
      alert: (if $alert then {id: $alert.id, status: $alert.status, value: $alert.value, opened_at: ($alert.openedAt | todate), closed_at: (if $alert.closedAt then ($alert.closedAt | todate) else null end)} else null end),
      monitor: (if $monitor then {id: $monitor.id, name: $monitor.name, type: $monitor.type, query: $monitor.query, operator: $monitor.operator, warning: $monitor.warning, critical: $monitor.critical} else null end),
      focus_services: $focus,
      services: $services,
      traces: ($traces | map(. as $t | . + {logs_urls: ($t.services | map({(.): ($logs_base + . + $logs_q + "&filterTraceId=" + $t.trace_id + $logs_t)}) | add // {})})),
      hypotheses: (
        (if ($mismatch | length) > 0 then [{
            kind: "timeout_mismatch",
            title: "呼び出し側のタイムアウトが先に切れている（\($mismatch[0].from) → \($mismatch[0].to) \($mismatch[0].route)）",
            evidence: ($mismatch | map(.detail) | unique),
            cause: {
              direct: "\($mismatch[0].from) は約 \($mismatch[0].client_ms) ms で諦めたが、その時点で \($mismatch[0].to) \($mismatch[0].route) はまだ応答していなかった（\($mismatch[0].to) 側は \($mismatch[0].server_ms) ms で正常終了）",
              structural: "\($mismatch[0].to) は結果を確定してから応答するため、タイムアウト後に結果が \($mismatch[0].to) 側にだけ残る。\($mismatch[0].from) のタイムアウトが \($mismatch[0].to) の処理時間より短い"
            },
            impact: "呼ばれた側（\($mismatch[0].to)）は処理を完了しているので、呼び出し側が失敗扱いにした処理の結果が残っている可能性がある（二重処理・不整合）",
            check_next: ["\($mismatch[0].to) のログで同じ業務キー（*.id / *_ref）の完了ログを確認する", "不整合を数えるゲージや照合ログ（reconcile / orphan / stale 等）があれば件数を見る", "コード: \($mismatch[0].from) のタイムアウト設定と、\($mismatch[0].to) で結果を確定する行と応答する行の順序（references/code-inspection.md）"],
            mitigation: ["\($mismatch[0].to) の遅延原因（直近のデプロイ・設定変更、依存先、リソース、負荷）を特定して止める", "復旧手段（照合 API、管理コマンド）がリポジトリにあれば、原因を止めた後に実行する"],
            permanent_fix: ["業務キーを冪等キーにして再送と照合を安全にする", "結果不明の失敗を補償処理か照合バッチで回収する", "\($mismatch[0].from) のタイムアウトを \($mismatch[0].to) の p99 より長くするか、処理を短くする"]
          }] else [] end)
        + (if ($fivexx | length) > 0 and ($mismatch | length) == 0 then [{
            kind: "downstream_5xx",
            title: "最も深い位置で 5xx を返しているのは \($fivexx[0].service) \($fivexx[0].route)（HTTP \($fivexx[0].http_status)）",
            evidence: ($fivexx | map("\(.service) \(.route) HTTP \(.http_status) ×\(.n)" + (if (.failure_reason | length) > 0 then "（\(.failure_reason | join(","))）" else "" end))),
            cause: {
              direct: "\($fivexx[0].service) \($fivexx[0].route) がエラーを返している" + (if ($fivexx[0].failure_reason | length) > 0 then "（理由: \($fivexx[0].failure_reason | join(", "))）" else "（理由はログ本文で確認）" end),
              structural: "起点サービスの依存先の失敗か設定不備が、上流に 5xx として伝播している"
            },
            impact: "上流の 5xx はこの伝播。起点の修正で連鎖が止まる",
            check_next: ["\($fivexx[0].service) の ERROR/WARN ログ（上の集計）で理由を確認する", "コード: failure_reason やエラー文字列を返す分岐と、そのルートのハンドラ（references/code-inspection.md）"],
            mitigation: ["\($fivexx[0].service) の直近の変更（デプロイ・設定・依存先）を特定して戻す"],
            permanent_fix: ["上流でのリトライ / フォールバックと、起点サービスのエラー予算の監視"]
          }] else [] end)
        + (if ($db | length) > 0 then [{
            kind: "db_error",
            title: "DB 操作が失敗している（\($db[0].service) \($db[0].operation)）",
            evidence: ($db | map(.detail) | unique),
            cause: {direct: "DB 操作が失敗している（\($db[0].status_message // "status.message を確認")）", structural: "接続プールの枯渇、ロック競合、スキーマ不一致、クエリのタイムアウト未設定のいずれか（確認が必要）"},
            impact: "そのサービスの書き込み/読み込みが失敗する",
            check_next: ["DB の接続数・ロック・ディスクを確認する", "コード: 接続プールの設定とクエリのタイムアウト（references/code-inspection.md）"], mitigation: ["DB 側の原因を取り除く（接続の解放、ロックの解消、容量）"], permanent_fix: ["接続プールとタイムアウトの設定、リトライ"]
          }] else [] end)
        + (if ($invariant_logs | length) > 0 then [{
            kind: "inconsistency_detected",
            title: "照合ログが不整合を報告している",
            evidence: ($invariant_logs | map("\(.service): \(.body) ×\(.count) \(.sample_attributes | tojson)") | unique | .[0:3]),
            cause: {direct: "照合ジョブ（\($invariant_logs[0].service)）が壊れた状態を検出している", structural: "他の仮説（タイムアウトの不一致など）で結果が片方にだけ残り、補償処理が無いため件数が溜まる"},
            impact: "業務データに手当てが必要な件数がある（アラートの値がその件数）",
            check_next: ["該当サービスの照合 API / 管理コマンドで一覧を取る", "コード: 照合ジョブの実装と復旧の API / コマンド（references/code-inspection.md）"],
            mitigation: ["原因を止めた後に、リポジトリにある復旧手段（照合 API、管理コマンド）を実行する。猶予時間があれば時間をおいて再実行する"],
            permanent_fix: ["失敗時の補償処理を自動化する"]
          }] else [] end)
        + (if ($mismatch | length) == 0 and ($fivexx | length) == 0 and ($db | length) == 0 then [{
            kind: "no_error_pattern",
            title: "代表トレースにエラーのパターンは無い（遅延かトラフィック量の問題の可能性）",
            evidence: ($services | map(.slow_routes[0]? | select(. != null) | "\(.route) p95 \(.p95_ms) ms") | unique | .[0:5]),
            cause: {direct: "", structural: ""},
            impact: "", check_next: ["遅いルートのトレースを --traces を増やして見る", "ダッシュボードで Requests / p99 の推移を見る"], mitigation: [], permanent_fix: []
          }] else [] end)
      )
    }')"

md="$(jq -r '
  def pct: (. * 10 | round / 10);
  # ログ本文・属性・span のメッセージはアプリや外部から入る信頼できないデータ。Markdown・リンク・メンションとして
  # 解釈されないようにインラインコードに入れ、改行を潰し、バッククォートを置き換え、長さを制限する
  def untrusted($n): tostring | gsub("[\\r\\n\\t]+"; " ") | gsub("`"; "\u0027") | (if length > $n then .[0:$n] + "…" else . end) | "`" + . + "`";
  def untrusted: untrusted(300);
  def attrs_text: to_entries | map("\(.key)=\(.value)") | join(" ");
  "# 一次調査レポート（Mackerel）",
  "",
  "- 生成: \(.generated_at)　窓: \(.window.from) 〜 \(.window.to)　namespace: `\(.namespace)`",
  (if .alert then "- アラート: [`\(.alert.id)`](\(.urls.alert)) \(.alert.status) 値 \(.alert.value // "-") 発生 \(.alert.opened_at)" + (if .alert.closed_at then "（\(.alert.closed_at) に閉鎖）" else "" end) else empty end),
  (if .monitor then "- 監視ルール: [**\(.monitor.name)**](\(.urls.monitor))（\(.monitor.operator // "") warn \(.monitor.warning // "-") / crit \(.monitor.critical // "-")）  `\(.monitor.query // .monitor.type)`" else empty end),
  "- 起点サービス: \(.focus_services | join(", "))",
  "",
  "## 仮説（根拠付き）",
  (.hypotheses[] | "### \(.title)", "- 種別: `\(.kind)`", (.evidence[] | "- 根拠: " + untrusted(400)),
     (if .cause.direct != "" then "- 直接原因: \(.cause.direct)" else empty end),
     (if .cause.structural != "" then "- 構造的な原因: \(.cause.structural)" else empty end),
     (if .impact != "" then "- 影響: \(.impact)" else empty end),
     (if (.check_next | length) > 0 then "- 次に確認: " + (.check_next | join(" / ")) else empty end),
     (if (.mitigation | length) > 0 then "- 止血: " + (.mitigation | join(" / ")) else empty end),
     (if (.permanent_fix | length) > 0 then "- 恒久対策: " + (.permanent_fix | join(" / ")) else empty end), ""),
  "## サービスごとの状況（APM ルート別統計と WARN/ERROR ログ）",
  (. as $r | .services[] | "### \(.service)  [APM](\($r.urls.apm[.service])) · [ログ](\($r.urls.logs[.service]))",
     (if (.error_routes | length) > 0 then (.error_routes[] | "- エラー: \(.method) \(.route)  \(.error_rate | pct)% / \(.requests) req  p95 \(.p95_ms | pct) ms") else "- エラーのあるルート: なし" end),
     (if (.slow_routes | length) > 0 then "- 遅い順: " + (.slow_routes | map("\(.route) p95 \(.p95_ms | pct) ms") | join(", ")) else empty end),
     (if .log_count > 0 then (.log_groups[] | "- ログ [\(.severity)] " + (.body | untrusted) + " ×\(.count)" + (if (.sample_attributes | length) > 0 then "  例: " + (.sample_attributes | attrs_text | untrusted(160)) else "" end)) else "- WARN/ERROR ログ: なし" end), ""),
  "## 代表トレース",
  (if (.traces | length) == 0 then "（候補なし）" else (.traces[] | . as $t
     | (([$t.business_keys[]? | tostring] + [$t.logs[]? | select(.severity != "INFO") | .attributes | to_entries[] | select(.key | test("(_|\\.)(id|ref)$")) | .value | tostring]) | map(select(length >= 4)) | unique) as $keys |
     "### [`\(.trace_id)`](\(.url))  \(.root.service) \(.root.name)  \(.root.duration_ms) ms  status=\(.root.status)",
     "- 画面: [トレース詳細](\(.url)) · ログ: " + (.logs_urls | to_entries | map("[\(.key)](\(.value))") | join(" ")),
     (if (.business_keys | length) > 0 then "- キー: " + (.business_keys | attrs_text | untrusted(200)) else empty end),
     (if (.findings | length) > 0 then (.findings[] | "- [\(.type)] " + (.detail | untrusted(400)) + (if .url then "（[span](\(.url))）" else "" end)) else "- 検出パターン: なし" end),
     "- 経路: " + ([.spans[] | select(.kind == "server") | "\(.service) \(.name) \(.duration_ms)ms" + (if .status == "error" then "(error)" else "" end)] | join(" → ")),
     (if (.logs | length) > 0 then "- ログ（同じ traceId。WARN/ERROR と、トレースの業務キーの値を含む INFO）:", (.logs[] | select(.severity != "INFO" or ((.body + " " + (.attributes | tojson)) as $txt | any($keys[]; . as $k | $txt | contains($k)))) | "  - \(.timestamp) \(.service) [\(.severity)] " + (.body | untrusted) + (if (.attributes | length) > 0 then " " + (.attributes | attrs_text | untrusted(200)) else "" end)) else empty end), "") end),
  "---",
  "再現コマンド: `scripts/trace.sh <traceId> --logs`、`scripts/logs.sh --service <svc> --grep <語>`。アラートを閉じる操作はこのスキルでは行わない。"
' <<< "$report")" || die "レポートの整形に失敗しました"

if [[ -n "$OUT" ]]; then
  mkdir -p "$OUT"
  jq . <<< "$report" > "$OUT/triage.json"
  printf '%s\n' "$md" > "$OUT/triage.md"
  log_ok "保存: ${OUT}/triage.md, triage.json, trace-*.json"
fi
if $JSON; then jq . <<< "$report"; else printf '%s\n' "$md"; fi
