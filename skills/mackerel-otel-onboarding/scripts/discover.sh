#!/usr/bin/env bash
# フェーズ 1: 検出。compose とビルドコンテキストからサービス構成を推定して inventory JSON を標準出力に出す
# 使い方: scripts/discover.sh [--compose-file FILE] [--pretty]
# 出力例は references/inventory-format.md を参照
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd docker jq

COMPOSE_ARGS=(); PRETTY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) COMPOSE_ARGS+=(-f "$2"); shift 2 ;;
    --pretty) PRETTY=true; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) die "不明な引数: $1" ;;
  esac
done

# 計装後の compose は `${MACKEREL_APIKEY:?}` でキーを補間する。compose はカレントディレクトリの .env を自分で読むので、
# 失敗するのはキーが環境変数にも .env にも無いとき（別ディレクトリから実行した場合など）
config="$(docker compose "${COMPOSE_ARGS[@]}" config --format json)" || die "docker compose config に失敗しました（計装後の compose なら MACKEREL_APIKEY を環境変数か、compose と同じディレクトリの .env に設定してください）"
project="$(jq -r '.name' <<< "$config")"

# Dockerfile から CMD / ENTRYPOINT の最後の 1 つを拾う
dockerfile_cmd() {
  local df="$1" key="$2"
  [[ -f "$df" ]] || return 0
  grep -iE "^\s*${key}\s" "$df" | tail -1 | sed -E "s/^\s*${key}\s+//I"
}

detect_service() {
  local name="$1" ctx="$2" dockerfile="$3"
  local lang="unknown" fw="" pkg="" module="" cmd="" entrypoint="" instrumented=false notes=()
  if [[ -n "$ctx" && -d "$ctx" ]]; then
    local df="$ctx/${dockerfile:-Dockerfile}"
    cmd="$(dockerfile_cmd "$df" CMD)"; entrypoint="$(dockerfile_cmd "$df" ENTRYPOINT)"
    if [[ -f "$ctx/package.json" ]]; then
      lang="node"; pkg="package.json"
      module="$(jq -r '.type // "commonjs"' "$ctx/package.json")"
      local deps; deps="$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$ctx/package.json")"
      for f in express fastify koa hono next nest; do grep -qx "$f" <<< "$deps" && fw="${fw:+$fw,}$f"; done
      grep -q "@opentelemetry/" <<< "$deps" && instrumented=true
      [[ -f "$ctx/package-lock.json" ]] && notes+=("package-lock.json あり（依存追加後に npm install で更新が必要）")
      [[ "$module" == "module" ]] && notes+=("ESM: ローダーフック（--experimental-loader）が必要")
      grep -qE "\.ts\b" <<< "$cmd $(jq -r '.scripts.start // ""' "$ctx/package.json")" && notes+=("TypeScript を直接実行している")
    elif [[ -f "$ctx/requirements.txt" || -f "$ctx/pyproject.toml" || -f "$ctx/Pipfile" ]]; then
      lang="python"
      for p in requirements.txt pyproject.toml Pipfile; do [[ -f "$ctx/$p" ]] && { pkg="$p"; break; }; done
      local pydeps; pydeps="$(tr '[:upper:]' '[:lower:]' < "$ctx/$pkg" 2>/dev/null)"
      for f in fastapi flask django starlette aiohttp; do grep -q "$f" <<< "$pydeps" && fw="${fw:+$fw,}$f"; done
      grep -q "opentelemetry" <<< "$pydeps" && instrumented=true
      grep -qE "uvicorn|gunicorn" <<< "$cmd $pydeps" && notes+=("ASGI/WSGI サーバー経由で起動（opentelemetry-instrument でラップ可能）")
    elif [[ -f "$ctx/go.mod" ]]; then
      lang="go"; pkg="go.mod"; module="$(head -1 "$ctx/go.mod" | awk '{print $2}')"
      for f in "github.com/go-chi/chi" "github.com/gin-gonic/gin" "github.com/labstack/echo" "github.com/gofiber/fiber" "github.com/gorilla/mux"; do
        grep -q "$f" "$ctx/go.mod" && fw="${fw:+$fw,}${f##*/}"
      done
      [[ -z "$fw" ]] && grep -rqE '"net/http"' "$ctx" --include='*.go' 2>/dev/null && fw="net/http"
      grep -q "go.opentelemetry.io" "$ctx/go.mod" && instrumented=true
      grep -q "github.com/jackc/pgx" "$ctx/go.mod" && notes+=("pgx を使用（otelpgx で SQL スパンを取れる）")
      grep -qE "database/sql" -r "$ctx" --include='*.go' 2>/dev/null && notes+=("database/sql を使用（otelsql で SQL スパンを取れる）")
    elif [[ -f "$ctx/Gemfile" ]]; then
      lang="ruby"; pkg="Gemfile"; grep -qi rails "$ctx/Gemfile" && fw="rails"; grep -qi sinatra "$ctx/Gemfile" && fw="${fw:+$fw,}sinatra"
      grep -q opentelemetry "$ctx/Gemfile" && instrumented=true
    elif [[ -f "$ctx/pom.xml" || -f "$ctx/build.gradle" || -f "$ctx/build.gradle.kts" ]]; then
      lang="java"; for p in pom.xml build.gradle build.gradle.kts; do [[ -f "$ctx/$p" ]] && { pkg="$p"; break; }; done
      grep -qi spring "$ctx/$pkg" && fw="spring"
    elif [[ -f "$ctx/composer.json" ]]; then
      lang="php"; pkg="composer.json"
    elif ls "$ctx"/*.csproj >/dev/null 2>&1; then
      lang="dotnet"; for p in "$ctx"/*.csproj; do pkg="$(basename "$p")"; break; done
    fi
  fi
  jq -n --arg lang "$lang" --arg fw "$fw" --arg pkg "$pkg" --arg module "$module" --arg cmd "$cmd" --arg ep "$entrypoint" \
        --argjson instrumented "$instrumented" --arg notes "$(printf '%s\n' "${notes[@]:-}")" \
        '{language: $lang, framework: ($fw | split(",") | map(select(. != ""))), manifest: $pkg, module: $module,
          dockerfile_cmd: $cmd, dockerfile_entrypoint: $ep, already_instrumented: $instrumented,
          notes: ($notes | split("\n") | map(select(. != "")))}'
}

services_json="[]"
while IFS=$'\t' read -r name ctx dockerfile image; do
  [[ "$ctx" == "null" ]] && ctx=""
  [[ "$dockerfile" == "null" ]] && dockerfile=""
  svc_cfg="$(jq --arg n "$name" '.services[$n]' <<< "$config")"
  detected="$(detect_service "$name" "$ctx" "$dockerfile")"
  entry="$(jq -n --arg name "$name" --arg ctx "$ctx" --arg image "$image" --argjson cfg "$svc_cfg" --argjson det "$detected" '
    {
      name: $name,
      kind: (if ($cfg.build // null) != null then "app" else "infra" end),
      image: (if $image == "null" then null else $image end),
      build_context: (if $ctx == "" then null else $ctx end),
      ports: [ ($cfg.ports // [])[] | "\(.published // "")->\(.target)" ],
      depends_on: (($cfg.depends_on // {}) | keys),
      upstream_env: [ (($cfg.environment // {}) | to_entries[]) | select(.key | test("URL|HOST|ENDPOINT|ADDR"; "i")) | {(.key): .value} ] | add // {},
      healthcheck: ($cfg.healthcheck.test // null),
      # ヘルスチェックの URL からパスを取り出す（CMD 配列でも CMD-SHELL 文字列でも）。メトリクスの除外ルートに使う
      healthcheck_path: (($cfg.healthcheck.test // null) | if . == null then null
        else (if type == "array" then join(" ") else tostring end)
          | (capture("https?://[^/ \"'\'']+(?<p>/[^ \"'\''?]*)") | .p) // null end),
      profiles: ($cfg.profiles // []),
      otel_env_present: (($cfg.environment // {}) | keys | map(select(startswith("OTEL_"))) | length > 0)
    } + $det')"
  services_json="$(jq --argjson e "$entry" '. + [$e]' <<< "$services_json")"
done < <(jq -r '.services | to_entries[] | [.key, (.value.build.context // "null"), (.value.build.dockerfile // "null"), (.value.image // "null")] | @tsv' <<< "$config")

# 既存の Collector を検出
collector="$(jq -r '[.[] | select((.image // "") | test("otelcol|opentelemetry-collector"))] | .[0].name // empty' <<< "$services_json")"

inventory="$(jq -n --arg project "$project" --arg collector "$collector" --argjson services "$services_json" '
  {
    project: $project,
    compose_files: (env.COMPOSE_FILE // "compose.yaml (default)"),
    existing_collector: (if $collector == "" then null else $collector end),
    app_services: [ $services[] | select(.kind == "app") | .name ],
    # メトリクスと監視から除外するルート。ヘルスチェックのパスを集め、見つからなければ /healthz
    exclude_routes: (([ $services[] | select(.kind == "app") | .healthcheck_path | select(. != null) ] | unique) as $r | if ($r | length) > 0 then $r else ["/healthz"] end),
    languages: ([ $services[] | select(.kind == "app") | .language ] | unique),
    services: $services
  }')"
if $PRETTY; then jq . <<< "$inventory"; else jq -c . <<< "$inventory"; fi
