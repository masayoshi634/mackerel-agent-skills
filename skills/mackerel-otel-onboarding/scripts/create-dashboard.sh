#!/usr/bin/env bash
# フェーズ 6: ダッシュボード作成（冪等）。サービスごとにリクエスト数・5xx 件数・p99 の query グラフを並べる
#   参考線と見出しの SLO 表は、create-monitors.sh が作った監視ルール（同じ接頭辞）から読む。監視ルールが無ければ引数と既定値
#   更新時は RED の行だけ作り直し、それ以外の既存ウィジェット（--extra で足したグラフなど）は残す
# 使い方: scripts/create-dashboard.sh [--project NAME] [--services a,b,c] [--prefix "[otel-onboarding:<project>]"]
#           [--exclude-routes "/healthz,/readyz"] [--error-warn 10] [--error-crit 50] [--p99-warn 1000] [--p99-crit 2000]
#           [--extra "タイトル|PromQL|凡例"]... [--dry-run]
#   --services / --exclude-routes を省略すると discover.sh の app_services / exclude_routes を使う
#   同じ urlPath のダッシュボードがあれば PUT で更新する（urlPath: otel-onboarding-<project>）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

PROJECT=""; SERVICES=""; PREFIX=""; EXCLUDE=""; ERR_WARN=10; ERR_CRIT=50; P99_WARN=1000; P99_CRIT=2000; DRY_RUN=false; EXTRAS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --services) SERVICES="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --exclude-routes) EXCLUDE="$2"; shift 2 ;;
    --error-warn) ERR_WARN="$2"; shift 2 ;;
    --error-crit) ERR_CRIT="$2"; shift 2 ;;
    --p99-warn) P99_WARN="$2"; shift 2 ;;
    --p99-crit) P99_CRIT="$2"; shift 2 ;;
    --extra) EXTRAS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done

[[ -z "$PROJECT" ]] && PROJECT="$(compose_project_name)"
[[ -z "$PROJECT" ]] && PROJECT="$(basename "$PWD")"
[[ -z "$PREFIX" ]] && PREFIX="$(default_prefix "$PROJECT")"
if [[ -z "$SERVICES" || -z "$EXCLUDE" ]]; then
  inventory="$("$SCRIPT_DIR/discover.sh" 2>/dev/null || echo '{}')"
  [[ -z "$SERVICES" ]] && SERVICES="$(jq -r '(.app_services // []) | join(",")' <<< "$inventory")"
  [[ -z "$EXCLUDE" ]] && EXCLUDE="$(inventory_exclude_routes "$inventory")"
fi
[[ -z "$SERVICES" ]] && die "対象サービスがありません（--services で指定してください）"
[[ -z "$EXCLUDE" ]] && EXCLUDE="/healthz"
excl="$(route_exclusion "$EXCLUDE")"

url_path="$(dashboard_url_path "$PROJECT")"
title="[otel-onboarding] ${PROJECT}"
now_iso="$(date -u +%FT%TZ)"

# 既存の監視ルール（しきい値と SLO の読み出し）と既存ダッシュボード。dry-run でキーが無ければ無しとして扱う
monitors='{"monitors":[]}'
if ! $DRY_RUN; then
  load_api_key
  monitors="$(mkr_api GET /api/v0/monitors)"
elif [[ -n "${MACKEREL_APIKEY:-}" ]]; then
  monitors="$(mkr_api GET /api/v0/monitors 2>/dev/null || echo '{"monitors":[]}')"
fi
monitor_field() { jq -r --arg n "$1" --arg f "$2" '[.monitors[] | select(.name == $n)] | .[0] | .[$f] // empty' <<< "$monitors"; }

# PromQL（Mackerel はヒストグラムを .count/.p99 等の代表値に変換する。histogram_quantile は使えない）
# 参考線（referenceLines）は 1 本までなので critical だけ引く
sel() { printf 'service.name="%s",%s' "$1" "$excl"; }
q_requests() { printf 'sum by (http.route) (increase(http.server.request.duration.count{%s}[5m]))' "$(sel "$1")"; }
# Mackerel の PromQL はベクトル同士の除算（/）に対応していない（実機確認済み）ため、エラー率(%)ではなく
# 5xx 件数を「全体 - 非5xx」で求める。この形なら 5xx が 0 件のときも 0 が描ける
q_errors() { printf 'sum(increase(http.server.request.duration.count{%s}[5m])) - sum(increase(http.server.request.duration.count{%s,http.response.status_code!~"5.."}[5m]))' "$(sel "$1")" "$(sel "$1")"; }
q_p99() { printf 'max by (http.route) (http.server.request.duration.p99{%s}) * 1000' "$(sel "$1")"; }

# サービスごとのしきい値と SLO を監視ルールから集める（無ければ引数 / 既定）
mapfile -t svc_list < <(split_csv "$SERVICES")
declare -A T_EW=() T_EC=() T_PW=() T_PC=() T_SLO=()
slo_rows=""
for svc in "${svc_list[@]}"; do
  n_err="${PREFIX} ${svc} 5xx errors"; n_p99="${PREFIX} ${svc} p99 latency"
  T_EW[$svc]="$(monitor_field "$n_err" warning)"; T_EC[$svc]="$(monitor_field "$n_err" critical)"
  T_PW[$svc]="$(monitor_field "$n_p99" warning)"; T_PC[$svc]="$(monitor_field "$n_p99" critical)"
  T_SLO[$svc]="$(memo_slo_line "$(monitor_field "$n_err" memo)")"
  : "${T_EW[$svc]:=$ERR_WARN}" "${T_EC[$svc]:=$ERR_CRIT}" "${T_PW[$svc]:=$P99_WARN}" "${T_PC[$svc]:=$P99_CRIT}"
  slo_rows+="| ${svc} | ${T_EW[$svc]} / ${T_EC[$svc]} | ${T_PW[$svc]} / ${T_PC[$svc]} | ${T_SLO[$svc]:-（未設定）} |"$'\n'
done

widgets="[]"
add_widget() { widgets="$(jq --argjson w "$1" '. + [$w]' <<< "$widgets")"; }

header_md="$(cat <<MD
## ${PROJECT} — OpenTelemetry で計装したサービスの RED メトリクス

- **Requests**: 5 分あたりのリクエスト数（ルート別） / **5xx errors**: 5 分あたりの 5xx 件数 / **p99**: レイテンシの 99 パーセンタイル (ms)
- 参考線は監視ルール \`${PREFIX} ...\` の critical と同じ値。しきい値は監視ルール側（\`scripts/create-monitors.sh --svc\`）で変え、このダッシュボードを再実行すると追従する
- トレースとルート別の詳細は APM → サービス一覧から各サービスを開く。このダッシュボードは \`mackerel-otel-onboarding\` スキルが生成（${now_iso}）

| サービス | 5xx warn / crit（件/5分） | p99 warn / crit (ms) | SLO |
|---|---|---|---|
${slo_rows}
MD
)"
add_widget "$(jq -n --arg t "$title" --arg md "$header_md" --argjson h "$(( 6 + ${#svc_list[@]} ))" '{type:"markdown", title:$t, markdown:$md, layout:{x:0,y:0,width:24,height:$h}}')"

y=$(( 6 + ${#svc_list[@]} ))
for svc in "${svc_list[@]}"; do
  add_widget "$(jq -n --arg t "${svc}: Requests / 5m" --arg q "$(q_requests "$svc")" --argjson y "$y" \
    '{type:"graph", title:$t, graph:{type:"query", query:$q, legend:"{{http.route}}"}, valueRange:{min:0}, layout:{x:0,y:$y,width:8,height:8}}')"
  add_widget "$(jq -n --arg t "${svc}: 5xx errors / 5m" --arg q "$(q_errors "$svc")" --argjson y "$y" --argjson c "${T_EC[$svc]}" \
    '{type:"graph", title:$t, graph:{type:"query", query:$q, legend:"5xx"}, valueRange:{min:0}, referenceLines:[{label:"critical",value:$c}], layout:{x:8,y:$y,width:8,height:8}}')"
  add_widget "$(jq -n --arg t "${svc}: p99 latency (ms)" --arg q "$(q_p99 "$svc")" --argjson y "$y" --argjson c "${T_PC[$svc]}" \
    '{type:"graph", title:$t, graph:{type:"query", query:$q, legend:"{{http.route}}"}, valueRange:{min:0}, referenceLines:[{label:"critical",value:$c}], layout:{x:16,y:$y,width:8,height:8}}')"
  y=$((y + 8))
done

# 既存ダッシュボードの RED 以外のウィジェット（以前の --extra など）を、並びを保ったまま RED の下に移す
existing_id=""
if ! $DRY_RUN || [[ -n "${MACKEREL_APIKEY:-}" ]]; then
  existing_id="$(mkr_api GET /api/v0/dashboards 2>/dev/null | jq -r --arg u "$url_path" '.dashboards[] | select(.urlPath == $u) | .id' | head -1 || true)"
fi
extra_titles="$(printf '%s\n' "${EXTRAS[@]:-}" | cut -d'|' -f1 | jq -R . | jq -sc 'map(select(. != ""))')"
if [[ -n "$existing_id" ]]; then
  kept="$(mkr_api GET "/api/v0/dashboards/${existing_id}" | jq -c --arg t "$title" --argjson new "$extra_titles" '
    [ .widgets[]
      | select(.title != $t)
      | select((.title | test("^[^:]+: (Requests / 5m|5xx errors / 5m|p99 latency \\(ms\\))$")) | not)
      | .title as $tt | select(($new | index($tt)) == null) ]')"
  n_kept="$(jq 'length' <<< "$kept")"
  if (( n_kept > 0 )); then
    min_y="$(jq '[.[].layout.y] | min' <<< "$kept")"
    widgets="$(jq --argjson k "$kept" --argjson y "$y" --argjson min "$min_y" '. + ($k | map(.layout.y += ($y - $min)))' <<< "$widgets")"
    y="$(jq '[.[] | .layout.y + .layout.height] | max' <<< "$widgets")"
    log_info "既存のウィジェット ${n_kept} 件を保持します"
  fi
fi

if (( ${#EXTRAS[@]} )); then
  x=0
  for e in "${EXTRAS[@]}"; do
    IFS='|' read -r et eq el <<< "$e"
    [[ -z "$eq" ]] && die "--extra の形式は 'タイトル|PromQL|凡例' です: $e"
    add_widget "$(jq -n --arg t "$et" --arg q "$eq" --arg l "${el:-}" --argjson x "$x" --argjson y "$y" \
      '{type:"graph", title:$t, graph:{type:"query", query:$q, legend:$l}, layout:{x:$x,y:$y,width:12,height:8}}')"
    x=$((x + 12)); if (( x >= 24 )); then x=0; y=$((y + 8)); fi
  done
fi

body="$(jq -n --arg t "$title" --arg u "$url_path" --arg memo "mackerel-otel-onboarding スキルが生成。scripts/create-dashboard.sh を再実行すると RED の行が更新され、他のグラフは残る。scripts/teardown.sh で削除。" --argjson w "$widgets" \
  '{title:$t, memo:$memo, urlPath:$u, widgets:$w}')"

if $DRY_RUN; then jq . <<< "$body"; exit 0; fi

org="$(mackerel_org_name)"
if [[ -n "$existing_id" ]]; then
  log_info "既存のダッシュボード（urlPath=${url_path}）を更新します"
  res="$(mkr_api PUT "/api/v0/dashboards/${existing_id}" "$body")"
else
  log_info "ダッシュボードを作成します（urlPath=${url_path}）"
  res="$(mkr_api POST /api/v0/dashboards "$body")"
fi
id="$(jq -r '.id' <<< "$res")"
url="${MACKEREL_WEB_BASE}/orgs/${org}/dashboards/${url_path}"
log_ok "ダッシュボード: ${url}"
jq -n --arg id "$id" --arg url "$url" --arg urlPath "$url_path" --arg title "$title" --argjson widgets "$(jq 'length' <<< "$widgets")" \
  '{id:$id, url:$url, urlPath:$urlPath, title:$title, widgets:$widgets}'
