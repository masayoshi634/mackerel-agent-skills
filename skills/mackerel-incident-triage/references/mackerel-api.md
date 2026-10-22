# 使う Mackerel API と応答の形（triage 向け）

ベース URL `https://api.mackerelio.com`、認証ヘッダ `X-Api-Key`。`scripts/lib.sh` の `mkr_api METHOD PATH [BODY]` を使う（429 / 5xx は待って再試行）。
すべて **読み取り**（GET と検索の POST）。実機で確認した形を書く（2026-10）。

| 用途 | API | 返るもの |
|---|---|---|
| キー検証・組織名 | `GET /api/v0/org` | `name` |
| アラート一覧 | `GET /api/v0/alerts?withClosed=true&limit=100` | `alerts[].{id, status(OK/WARNING/CRITICAL/UNKNOWN), monitorId, type, hostId, value, openedAt, closedAt, memo}`。`series.labels` は query 監視でも空だった |
| 監視ルール一覧 | `GET /api/v0/monitors` | `monitors[].{id, name, type, query, operator, warning, critical, memo, url, metric, service, scopes}`（`query` は query 監視、`metric` / `scopes` はホストメトリック監視、`service` / `metric` はサービスメトリック監視、`url` は外形監視） |
| ルート別統計（APM） | `GET /api/v0/apm/http-server-stats?serviceName&serviceNamespace&from&to&orderColumn=REQUEST_COUNT` | `results[].{method, route, requestCount, errorRatePercentage, approxP95Millis}` |
| トレース検索 | `POST /api/v0/traces` `{serviceName, serviceNamespace, from, to, perPage, order:{column, direction}}` | `results[].{traceId, serviceName, title, traceStartAt, traceLatencyMillis, serviceLatencyMillis}`、`hasNextPage` |
| トレース詳細 | `GET /api/v0/traces/{traceId}` | `spans[]`（下記） |
| ログ検索 | `POST /api/v0/logs` `{serviceName, serviceNamespace, from, to, perPage, severities:["ERROR","WARN"]}` | `results[].{timestamp, severity, body, traceId, spanId, attributes[], resourceAttributes[]}`、`pagination.{hasNextPage, endCursor}` |
| ホストメトリックの値 | `GET /api/v0/hosts/{hostId}/metrics?name&from&to`（epoch 秒） | `metrics[].{time, value}`（古い順）。無いと 404 |
| メトリックの最新値 | `GET /api/v0/tsdb/latest?hostId&name`（複数可） | `tsdbLatest.{hostId}.{name}.{time, value}` |
| サービスメトリックの値 | `GET /api/v0/services/{serviceName}/metrics?name&from&to` | `metrics[].{time, value}`。無いと 404 |

`scripts/metrics.sh` がホスト・サービスメトリックの値を取って前後比較する。**OpenTelemetry のラベル付きメトリクス（query 監視の対象）を取る API は無い**（公式 API 一覧に PromQL のクエリ API は無い。2026-10 に確認）。query 監視のメトリクスは、アラートの `value` と APM 統計で代替し、グラフはダッシュボードかメトリックエクスプローラーで見る。

## 画面の URL（2026-10 に実機で確認）

| 画面 | URL |
|---|---|
| アラート詳細 | `https://mackerel.io/orgs/<org>/alerts/<alertId>` |
| 監視ルール詳細 | `https://mackerel.io/orgs/<org>/monitors/<monitorId>` |
| ダッシュボード | `https://mackerel.io/orgs/<org>/dashboards/<urlPath>#period=30m` |
| APM のサービス（トレース一覧） | `https://mackerel.io/orgs/<org>/traces?service=<svc>&serviceNamespace=<ns>[&traceId=<id>]#period=30m` |
| トレース詳細 | `https://mackerel.io/orgs/<org>/traces/<traceId>[?spanId=<spanId>]` |
| ログ検索 | `https://mackerel.io/orgs/<org>/logs/search?service=<svc>&serviceNamespace=<ns>&timezone=Local&severities=DEBUG,ERROR,FATAL,INFO,TRACE,WARN[&filterTraceId=<traceId>]#t=<fromISO>,<toISO>` |

`scripts/lib.sh` の `url_alert` / `url_monitor` / `url_dashboard` / `url_apm_traces` / `url_trace` / `url_logs` がこの形式で組み立てる（先に `ensure_org`）。`alerts.sh` / `triage.sh` / `trace.sh` の出力にも `url` が入る。

## 監視ルールの種別と辿れる範囲

| `monitor.type` | 対象の決め方 | 辿れるもの | 辿れないもの |
|---|---|---|---|
| `query`（PromQL） | `service.name="..."` があればそのサービス。無ければメトリクス名の区切りからサービスを推定（`shop.checkout.x` → `checkout`） | APM 統計、トレース、ログ（計装済みなら） | メトリクスの推移（API 無し。アラートの値のみ） |
| `host`（ホストメトリック） | アラートの `hostId`、監視ルールの `metric` | `metrics.sh --host` でメトリクスの推移 | トレース・ログ（ホストが OTel のサービスと対応しない限り） |
| `service`（サービスメトリック） | 監視ルールの `service` と `metric` | `metrics.sh --service` で推移 | 同上 |
| `external`（外形） | 監視ルールの `url` | 応答時間・ステータス（アラートの値と memo） | 内部の統計（URL が計装済みサービスの入口なら、そのサービスを `--service` で指定して APM・トレースを見る） |
| `check` / `connectivity` | アラートの `hostId` | ホスト側の状態 | トレース・ログ |
| `expression` / `anomalyDetection` | 式・対象ホスト | アラートの値 | トレース・ログ |

## span の形（トレース詳細）

```
spanId, parentSpanId, traceId, name, kind(server|client|internal|producer|consumer),
startTime, endTime（RFC 3339、ミリ秒まで）, status.{code: unset|ok|error, message},
attributes[] {key, value:{valueType, stringValue|intValue|doubleValue|boolValue}},
resource.attributes[]（service.name, service.namespace, deployment.environment.name, telemetry.sdk.*）,
scope.{name, version}, events[] {name, time, attributes[]}
```

- サービス名は `resource.attributes` の `service.name`。span の直下には無い。
- HTTP の server span: `http.route`, `http.request.method`, `http.response.status_code`, `server.address`。client span: `url.full`, `server.address`, `http.response.status_code`（タイムアウト時は無い）。
- DB の client span: `db.system.name`, `db.query.text`, `db.operation.name`。
- アプリが付けた属性（`<entity>.id`、`<domain>.failure_reason` など）と event はそのまま入る。`trace.sh` は `*.failure_reason` / `error.type` を失敗理由、`*.id` / `*_id` / `*_ref` を業務キーとして拾う。

## 検索の制限と落とし穴

- `from`〜`to` は **最大 30 分**（トレース検索・APM 統計・ログ検索とも。超えると 400）。ホスト・サービスメトリックにはこの制限は無い。
- トレース検索の `order.column` は `START_AT` と `LATENCY` だけ。**エラーで絞る条件は無い**。エラーのトレースは「WARN/ERROR ログの traceId」から辿る（これが一番確実）か、遅い順で拾う。
- ログ検索は `severities` で絞れる。本文のキーワード・`traceId`・属性での絞り込みは **API に無い**（`traceId` を渡すと 400）。`perPage` 100 で取ってクライアント側で絞る。
- `serviceNamespace` を付け忘れると空文字で検索されて 0 件になる。
- レート制限は厳しい（**HTTP 429**。連続呼び出しで出る）。`mkr_api` は待って再試行するが、サービスごとの呼び出しの間に 1 秒置く。
- トレースは送信から見えるまで 1〜2 分、ログも同程度。
- Mackerel の `GET /api/v0/services` は OpenTelemetry のサービスを返さない（空）。サービス一覧は監視ルールの PromQL から集めるか、ユーザーに `--services` でもらう。
