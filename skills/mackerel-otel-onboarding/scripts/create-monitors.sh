#!/usr/bin/env bash
# フェーズ 5: 監視ルール作成（冪等）。サービスごとに 5xx 件数と p99 の query 監視を作る。
#   指定しなかったしきい値は既存ルールの値を保ち、--extra で作ったルールは削除しない（再実行しても何も勝手に消えない）
# 使い方: scripts/create-monitors.sh [--project NAME] [--services a,b,c] [--prefix "[otel-onboarding:<project>]"]
#           [--exclude-routes "/healthz,/readyz"] [--error-warn 10] [--error-crit 50] [--p99-warn 1000] [--p99-crit 2000]
#           [--svc "名前|err=warn/crit|p99=warn/crit|slo=99.9%,1000ms|note=根拠"]...
#           [--evaluate-backward 1] [--notification-interval 60] [--public-url URL]
#           [--extra "名前|PromQL|warn|crit[|演算子]"]... [--dry-run]
#   しきい値の優先順位: --svc > --error-*/--p99-*（明示したとき） > 既存ルールの値 > 既定（10/50 件、1000/2000 ms）
#     --error-warn/--error-crit（--p99-warn/--p99-crit）は対で全サービスに適用する。片方だけ指定すると、もう片方は既定値になる
#   --svc の slo と note は memo に書かれ、Mackerel の画面と report.sh で根拠として読める（--svc が無いサービスは既存の memo を保つ）
#   --exclude-routes を省略すると discover.sh が compose のヘルスチェックから検出した exclude_routes を使う
#   削除するのは "<prefix> <service> 5xx errors|p99 latency" の形で、compose に存在しなくなったサービスのルールだけ
#   --extra はビジネスメトリクスや不変条件のゲージに対する query 監視を追加する（名前には prefix が付く）。
#     warn / crit は数値。どちらかは空にできる。演算子は > (既定) か <。例: --extra "stale jobs|max(app.jobs.stale)||0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd curl jq

PROJECT=""; SERVICES=""; PREFIX=""; EXCLUDE=""; ERR_WARN=10; ERR_CRIT=50; P99_WARN=1000; P99_CRIT=2000
ERR_SET=false; P99_SET=false
EVAL_BACK=1; NOTIFY_INTERVAL=60; PUBLIC_URL=""; DRY_RUN=false; EXTRAS=(); SVC_SPECS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --services) SERVICES="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --exclude-routes) EXCLUDE="$2"; shift 2 ;;
    --error-warn) ERR_WARN="$2"; ERR_SET=true; shift 2 ;;
    --error-crit) ERR_CRIT="$2"; ERR_SET=true; shift 2 ;;
    --p99-warn) P99_WARN="$2"; P99_SET=true; shift 2 ;;
    --p99-crit) P99_CRIT="$2"; P99_SET=true; shift 2 ;;
    --svc) SVC_SPECS+=("$2"); shift 2 ;;
    --evaluate-backward) EVAL_BACK="$2"; shift 2 ;;
    --notification-interval) NOTIFY_INTERVAL="$2"; shift 2 ;;
    --public-url) PUBLIC_URL="$2"; shift 2 ;;
    --extra) EXTRAS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ -z "$PROJECT" ]] && PROJECT="$(compose_project_name)"
[[ -z "$PROJECT" ]] && PROJECT="$(basename "$PWD")"
[[ -z "$PREFIX" ]] && PREFIX="$(default_prefix "$PROJECT")"
# compose にある app サービスの一覧（削除判定の基準）と除外ルートは discover.sh から取る
inventory="$("$SCRIPT_DIR/discover.sh" 2>/dev/null || echo '{}')"
app_services="$(jq -r '(.app_services // []) | join(",")' <<< "$inventory")"
[[ -z "$SERVICES" ]] && SERVICES="$app_services"
[[ -z "$SERVICES" ]] && die "対象サービスがありません（--services で指定してください）"
[[ -z "$EXCLUDE" ]] && EXCLUDE="$(inventory_exclude_routes "$inventory")"
[[ -z "$EXCLUDE" ]] && EXCLUDE="/healthz"
excl="$(route_exclusion "$EXCLUDE")"
sel() { printf 'service.name="%s",%s' "$1" "$excl"; }
is_num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

# --svc の解釈: "名前|err=warn/crit|p99=warn/crit|slo=...|note=..."（err / p99 / slo / note はそれぞれ任意）
declare -A SVC_ERR_W=() SVC_ERR_C=() SVC_P99_W=() SVC_P99_C=() SVC_SLO=() SVC_NOTE=() SVC_GIVEN=()
for spec in "${SVC_SPECS[@]}"; do
  IFS='|' read -r -a parts <<< "$spec"
  name="${parts[0]:-}"
  [[ -n "$name" ]] || die "--svc の形式は '名前|err=warn/crit|p99=warn/crit|slo=...|note=...' です: $spec"
  SVC_GIVEN[$name]=1
  for kv in "${parts[@]:1}"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      err|p99)
        w="${val%%/*}"; c="${val#*/}"
        [[ "$val" == */* ]] || die "--svc の ${key} は warn/crit の形です: $spec"
        if ! is_num "$w" || ! is_num "$c"; then die "--svc の ${key} は数値です: $spec"; fi
        if [[ "$key" == err ]]; then SVC_ERR_W[$name]="$w"; SVC_ERR_C[$name]="$c"; else SVC_P99_W[$name]="$w"; SVC_P99_C[$name]="$c"; fi ;;
      slo) SVC_SLO[$name]="$val" ;;
      note) SVC_NOTE[$name]="$val" ;;
      *) die "--svc の不明なキー '${key}': $spec" ;;
    esac
  done
done

# 既存ルール（しきい値と memo の引き継ぎ、削除判定に使う）。dry-run でキーが無ければ空として扱う
existing='{"monitors":[]}'
if ! $DRY_RUN; then
  load_api_key
  existing="$(mkr_api GET /api/v0/monitors)"
elif [[ -n "${MACKEREL_APIKEY:-}" ]]; then
  existing="$(mkr_api GET /api/v0/monitors 2>/dev/null || echo '{"monitors":[]}')"
fi
existing_by_name() { jq -c --arg n "$1" '[.monitors[] | select(.name == $n)] | .[0] // empty' <<< "$existing"; }

base_memo="mackerel-otel-onboarding スキルが生成（project: ${PROJECT}）。しきい値は scripts/create-monitors.sh の --svc \"<service>|err=warn/crit|p99=warn/crit\" で変更して再実行（err は 5 分あたりの 5xx 件数、p99 は ms。指定しない値は保たれる）。"
# サービスの memo: --svc があれば slo / note から組み立てる。slo / note を省いた差分指定（--svc "S|p99=..."）では
# 既存ルールの memo にある SLO と根拠の行を引き継ぐ。--svc が無ければ既存ルールの memo をそのまま保つ
service_memo() {
  local svc="$1" cur="$2" m="$base_memo" cur_memo=""
  local slo="${SVC_SLO[$svc]:-}" note="${SVC_NOTE[$svc]:-}"
  [[ -n "$cur" ]] && cur_memo="$(jq -r '.memo // ""' <<< "$cur")"
  if [[ -n "${SVC_GIVEN[$svc]:-}" ]]; then
    [[ -z "$slo" ]] && slo="$(memo_slo_line "$cur_memo")"
    [[ -z "$note" ]] && note="$(sed -n 's/^根拠: //p' <<< "$cur_memo" | head -1)"
    [[ -n "$slo" ]] && m+=$'\n'"SLO: ${slo}"
    [[ -n "$note" ]] && m+=$'\n'"根拠: ${note}"
    printf '%s' "$m"
  elif [[ -n "$cur" ]]; then
    printf '%s' "$cur_memo"
  else
    printf '%s' "$m"
  fi
}
# しきい値の解決: --svc > 明示した --error-*/--p99-* > 既存ルール > 既定
resolve() {
  local svc="$1" kind="$2" field="$3" cur="$4" flag_set="$5" flag_val="$6" v=""
  case "$kind:$field" in
    err:warning) v="${SVC_ERR_W[$svc]:-}" ;; err:critical) v="${SVC_ERR_C[$svc]:-}" ;;
    p99:warning) v="${SVC_P99_W[$svc]:-}" ;; p99:critical) v="${SVC_P99_C[$svc]:-}" ;;
  esac
  [[ -z "$v" && "$flag_set" == true ]] && v="$flag_val"
  [[ -z "$v" && -n "$cur" ]] && v="$(jq -r --arg f "$field" '.[$f] // empty' <<< "$cur")"
  [[ -z "$v" ]] && v="$flag_val"
  printf '%s' "$v"
}

monitors="[]"
add_monitor() { monitors="$(jq --argjson m "$1" '. + [$m]' <<< "$monitors")"; }
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  n_err="${PREFIX} ${svc} 5xx errors"; n_p99="${PREFIX} ${svc} p99 latency"
  cur_err="$(existing_by_name "$n_err")"; cur_p99="$(existing_by_name "$n_p99")"
  ew="$(resolve "$svc" err warning "$cur_err" "$ERR_SET" "$ERR_WARN")"; ec="$(resolve "$svc" err critical "$cur_err" "$ERR_SET" "$ERR_CRIT")"
  pw="$(resolve "$svc" p99 warning "$cur_p99" "$P99_SET" "$P99_WARN")"; pc="$(resolve "$svc" p99 critical "$cur_p99" "$P99_SET" "$P99_CRIT")"
  memo_err="$(service_memo "$svc" "$cur_err")"; memo_p99="$(service_memo "$svc" "$cur_p99")"
  # Mackerel の PromQL はベクトル除算に対応しないため、率ではなく 5 分あたりの 5xx 件数（全体 - 非5xx）で監視する
  add_monitor "$(jq -n --arg name "$n_err" --arg memo "$memo_err" --arg svc "$svc" \
    --arg q "sum(increase(http.server.request.duration.count{$(sel "$svc")}[5m])) - sum(increase(http.server.request.duration.count{$(sel "$svc"),http.response.status_code!~\"5..\"}[5m]))" \
    --argjson w "$ew" --argjson c "$ec" --argjson eb "$EVAL_BACK" --argjson ni "$NOTIFY_INTERVAL" \
    '{type:"query", name:$name, memo:$memo, query:$q, legend:($svc + " 5xx / 5m"), operator:">", warning:$w, critical:$c, evaluateBackwardMinutes:$eb, notificationInterval:$ni}')"
  add_monitor "$(jq -n --arg name "$n_p99" --arg memo "$memo_p99" --arg svc "$svc" \
    --arg q "max(http.server.request.duration.p99{$(sel "$svc")}) * 1000" \
    --argjson w "$pw" --argjson c "$pc" --argjson eb "$EVAL_BACK" --argjson ni "$NOTIFY_INTERVAL" \
    '{type:"query", name:$name, memo:$memo, query:$q, legend:($svc + " p99 ms"), operator:">", warning:$w, critical:$c, evaluateBackwardMinutes:$eb, notificationInterval:$ni}')"
done < <(split_csv "$SERVICES")
for s in "${!SVC_GIVEN[@]}"; do
  grep -qx "$s" < <(split_csv "$SERVICES") || log_warn "--svc '${s}' は対象サービスにありません（無視します）"
done

for e in "${EXTRAS[@]}"; do
  IFS='|' read -r en eq ew ec eo <<< "$e"
  [[ -n "$en" && -n "$eq" ]] || die "--extra の形式は '名前|PromQL|warn|crit[|演算子]' です: $e"
  [[ -n "$ew" || -n "$ec" ]] || die "--extra は warn か crit の少なくとも一方が必要です: $e"
  for v in "$ew" "$ec"; do
    [[ -z "$v" ]] || is_num "$v" || die "--extra のしきい値は数値です: $e"
  done
  eo="${eo:->}"
  [[ "$eo" == ">" || "$eo" == "<" ]] || die "--extra の演算子は > か < です: $e"
  add_monitor "$(jq -n --arg name "${PREFIX} ${en}" --arg memo "$base_memo" --arg q "$eq" --arg legend "$en" --arg op "$eo" \
    --arg w "$ew" --arg c "$ec" --argjson eb "$EVAL_BACK" --argjson ni "$NOTIFY_INTERVAL" \
    '{type:"query", name:$name, memo:$memo, query:$q, legend:$legend, operator:$op, evaluateBackwardMinutes:$eb, notificationInterval:$ni}
     + (if $w != "" then {warning:($w|tonumber)} else {} end)
     + (if $c != "" then {critical:($c|tonumber)} else {} end)')"
done

if [[ -n "$PUBLIC_URL" ]]; then
  add_monitor "$(jq -n --arg name "${PREFIX} external ${PROJECT}" --arg memo "$base_memo" --arg url "$PUBLIC_URL" --argjson ni "$NOTIFY_INTERVAL" \
    '{type:"external", name:$name, memo:$memo, url:$url, method:"GET", responseTimeWarning:1000, responseTimeCritical:3000, responseTimeDuration:3, maxCheckAttempts:3, notificationInterval:$ni}')"
fi

# 削除候補: RED のルール名の形で、compose の app サービスに無いもの（--extra や外形監視は触らない）
# compose を検出できない環境（app_services が空）では判定できないので削除しない
prune="[]"
[[ -z "$app_services" ]] && log_warn "compose からサービス一覧を取れないため、不要になったルールの削除は行いません"
[[ -n "$app_services" ]] && prune="$(jq -c --arg p "$PREFIX" --arg apps "$app_services" '
  ($apps | split(",") | map(select(. != ""))) as $a
  | [.monitors[] | select(.name | startswith($p + " "))
      | (.name | ltrimstr($p + " ")) as $rest
      | select($rest | test(" (5xx errors|p99 latency)$"))
      | ($rest | sub(" (5xx errors|p99 latency)$"; "")) as $svc
      | select(($a | index($svc)) == null)
      | {id, name}]' <<< "$existing")"

if $DRY_RUN; then jq -n --argjson m "$monitors" --argjson p "$prune" '{monitors:$m, prune:$p}'; exit 0; fi

org="$(mackerel_org_name)"
results="[]"
while IFS= read -r m; do
  name="$(jq -r '.name' <<< "$m")"
  cur="$(existing_by_name "$name")"
  id="$(jq -r '.id // empty' <<< "$cur")"
  if [[ -n "$id" ]]; then
    # Mackerel は監視対象（query / url）の変更を PUT で受け付けない（"cannot change target"）ので、
    # 対象が変わるときは削除して作り直す。しきい値だけの変更は PUT で更新する
    same_target="$(jq -n --argjson a "$cur" --argjson b "$m" '($a.query // $a.url // null) == ($b.query // $b.url // null)')"
    if [[ "$same_target" == "true" ]]; then
      res="$(mkr_api PUT "/api/v0/monitors/${id}" "$m")"; action="updated"
    else
      mkr_api DELETE "/api/v0/monitors/${id}" >/dev/null
      res="$(mkr_api POST /api/v0/monitors "$m")"; action="recreated"
    fi
  else
    res="$(mkr_api POST /api/v0/monitors "$m")"; action="created"
  fi
  id="$(jq -r '.id' <<< "$res")"
  log_ok "${action}: ${name} (${id})"
  results="$(jq --arg id "$id" --arg name "$name" --arg action "$action" --argjson m "$m" \
    '. + [{id:$id, name:$name, action:$action, type:$m.type, warning:($m.warning // null), critical:($m.critical // null)}]' <<< "$results")"
done < <(jq -c '.[]' <<< "$monitors")

while IFS=$'\t' read -r id name; do
  [[ -z "$id" ]] && continue
  mkr_api DELETE "/api/v0/monitors/${id}" >/dev/null && log_ok "pruned（compose に無いサービス）: ${name} (${id})"
  results="$(jq --arg id "$id" --arg name "$name" '. + [{id:$id, name:$name, action:"pruned"}]' <<< "$results")"
done < <(jq -r '.[] | "\(.id)\t\(.name)"' <<< "$prune")

jq -n --arg url "${MACKEREL_WEB_BASE}/orgs/${org}/monitors" --arg prefix "$PREFIX" --arg excl "$EXCLUDE" --argjson monitors "$results" \
  '{url:$url, prefix:$prefix, exclude_routes:$excl, monitors:$monitors}'
