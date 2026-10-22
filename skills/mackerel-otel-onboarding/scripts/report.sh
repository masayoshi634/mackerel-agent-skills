#!/usr/bin/env bash
# フェーズ 7: 完了レポート（Markdown）を標準出力に出す
# 使い方: scripts/report.sh [--project NAME] [--services a,b,c] [--namespace NS] [--prefix "[otel-onboarding:<project>]"]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

PROJECT=""; SERVICES=""; NAMESPACE=""; PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --services) SERVICES="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ -z "$PROJECT" ]] && PROJECT="$(compose_project_name)"
[[ -z "$PROJECT" ]] && PROJECT="$(basename "$PWD")"
[[ -z "$SERVICES" ]] && SERVICES="$("$SCRIPT_DIR/discover.sh" | jq -r '.app_services | join(",")')"
[[ -z "$NAMESPACE" ]] && NAMESPACE="$(detect_service_namespace)"
[[ -z "$PREFIX" ]] && PREFIX="$(default_prefix "$PROJECT")"
load_api_key
org="$(mackerel_org_name)"
url_path="$(dashboard_url_path "$PROJECT")"
dash="$(mkr_api GET /api/v0/dashboards | jq -r --arg u "$url_path" '.dashboards[] | select(.urlPath == $u) | .title' | head -1)"
monitors="$(mkr_api GET /api/v0/monitors | jq -c --arg p "$PREFIX" '[.monitors[] | select(.name | startswith($p))]')"
from=$(( $(date +%s) - 30 * 60 )); to=$(date +%s)

cat <<MD
# Mackerel 監視オンボーディング完了レポート

- 組織: **${org}**（${MACKEREL_WEB_BASE}/orgs/${org}）
- プロジェクト: \`${PROJECT}\` / service.namespace: \`${NAMESPACE:-（なし）}\`
- 生成日時: $(date -u +%FT%TZ)

## 見るところ

| 何を | どこで |
|---|---|
| ダッシュボード（RED メトリクス） | ${MACKEREL_WEB_BASE}/orgs/${org}/dashboards/${url_path} ${dash:+（${dash}）} |
| トレース・サービスマップ・ルート別統計 | ${MACKEREL_WEB_BASE}/orgs/${org} → APM → サービス一覧 |
| 監視ルールとアラート | ${MACKEREL_WEB_BASE}/orgs/${org}/monitors |
| ログ（有効にした場合） | ${MACKEREL_WEB_BASE}/orgs/${org} → ログ。トレース詳細のスパンからも辿れる |

## サービスごとの SLO としきい値

| サービス | 5xx warn / crit（件/5分） | p99 warn / crit (ms) | SLO | 根拠 |
|---|---|---|---|---|
$(while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    err="$(jq -c --arg n "${PREFIX} ${svc} 5xx errors" '[.[] | select(.name == $n)] | .[0] // {}' <<< "$monitors")"
    p99="$(jq -c --arg n "${PREFIX} ${svc} p99 latency" '[.[] | select(.name == $n)] | .[0] // {}' <<< "$monitors")"
    memo="$(jq -r '.memo // ""' <<< "$err")"
    slo="$(memo_slo_line "$memo")"; note="$(sed -n 's/^根拠: //p' <<< "$memo" | head -1)"
    printf '| %s | %s / %s | %s / %s | %s | %s |\n' "$svc" "$(jq -r '.warning // "-"' <<< "$err")" "$(jq -r '.critical // "-"' <<< "$err")" \
      "$(jq -r '.warning // "-"' <<< "$p99")" "$(jq -r '.critical // "-"' <<< "$p99")" "${slo:-（未設定）}" "${note:-}"
  done < <(split_csv "$SERVICES"))

## 作成した監視ルール（接頭辞 \`${PREFIX}\`）

| 名前 | 種別 | warning | critical |
|---|---|---|---|
$(jq -r '.[] | "| \(.name) | \(.type) | \(.warning // "-") | \(.critical // "-") |"' <<< "$monitors")

## 直近 30 分の各サービス（APM）

| サービス | ルート | 件数 | エラー率 | p95 |
|---|---|---|---|---|
MD
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  res="$(mkr_api GET "/api/v0/apm/http-server-stats?serviceName=${svc}&serviceNamespace=${NAMESPACE}&from=${from}&to=${to}&perPage=3&orderColumn=REQUEST_COUNT" 2>/dev/null || echo '{"results":[]}')"
  rows="$(jq -r --arg s "$svc" '.results[]? | "| \($s) | \(.method) \(.route) | \(.requestCount) | \(.errorRatePercentage)% | \(.approxP95Millis|floor) ms |"' <<< "$res")"
  if [[ -n "$rows" ]]; then echo "$rows"; else echo "| ${svc} | （データなし） | | | |"; fi
done < <(split_csv "$SERVICES")

cat <<MD

## 次にいじるところ

- しきい値や SLO を変える: AI に「checkout の p99 を 1500ms にして」のように伝えるか、\`scripts/create-monitors.sh --svc "checkout|p99=1200/1500|slo=可用性 99.95% / p99 1500ms|note=理由"\` を実行。指定しなかったサービスと値はそのまま保たれる
- ダッシュボードの参考線は監視ルールに追従する: \`scripts/create-dashboard.sh\` を再実行（追加したグラフは残る）
- ビジネスメトリクスの監視やグラフを足す: \`create-monitors.sh --extra\` / \`create-dashboard.sh --extra\`（\`references/business-metrics.md\`。再実行しても消えない）
- トラフィックが大きく変わったら SLO の件数しきい値を見直す（\`references/slo.md\` の再計算手順）
- ログ: まだ送っていなければ compose の \`OTEL_LOGS_EXPORTER\` を \`otlp\` にして再起動（\`references/logs.md\`）。量が多ければ Collector の \`filter/logs\` で絞る
- 通知先: Mackerel の [通知チャンネル] で Slack 等を追加し、通知グループに監視ルールを紐付ける
- 送信量: トレースは月 5M スパンまで無料。多い場合は Collector 設定の probabilistic_sampler を有効にする
- 全部消す: \`scripts/teardown.sh --project ${PROJECT} --yes\`（Mackerel 上のダッシュボードと監視ルールだけ削除。コードは git で戻す）
MD
