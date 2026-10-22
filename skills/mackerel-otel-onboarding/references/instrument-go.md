# Go の計装（コード追加あり）

Go は自動計装がないため、SDK 初期化とハンドラのラップをコードで行う。
変更は **新規ファイル 1 つ（otel.go）と main.go の数行** に収める。

## 手順

1. モジュールを追加する

   ```bash
   go get go.opentelemetry.io/otel go.opentelemetry.io/otel/sdk go.opentelemetry.io/otel/sdk/metric go.opentelemetry.io/otel/sdk/log \
     go.opentelemetry.io/otel/log/global \
     go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp \
     go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp \
     go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp \
     go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp \
     go.opentelemetry.io/contrib/bridges/otelslog
   go mod tidy
   ```

   ホストに Go がなければ `docker run --rm -v "$PWD:/src" -w /src golang:1.27-alpine sh -c 'go get ... && go mod tidy'`。

2. `assets/go/otel.go` をサービスの main パッケージにコピーする（`setupOTel`、`instrumentHTTP`、`withRouteAttribute`、`newLogger`）。
   パッケージ名が `main` でなければ合わせる。

3. `main.go` を変更する

   ```go
   // 起動時（signal.NotifyContext の直後など）。失敗してもアプリは止めない
   if shutdownOTel, err := setupOTel(ctx); err != nil {
       logger.Warn("opentelemetry disabled", "err", err)
   } else {
       defer func() { _ = shutdownOTel(context.Background()) }()
   }

   // ログ: stdout と OTel の両方へ（OTEL_LOGS_EXPORTER=none なら stdout だけ）
   logger := newLogger("my-service")
   slog.SetDefault(logger)

   // サーバー: 計装ハンドラを最外側にし、ログ・認証などのミドルウェアは内側に置く
   // （外側に置くと、そのミドルウェアのログに trace_id が付かず、ミドルウェアが返した応答が記録されない）
   srv := &http.Server{Handler: instrumentHTTP(withLogging(mux))}

   // 外向き HTTP クライアント: トレースを伝搬させる
   client := &http.Client{Timeout: 5 * time.Second, Transport: otelhttp.NewTransport(http.DefaultTransport)}
   ```

4. DB クライアント（任意だが APM の DB タブとウォーターフォールが充実する）

   - pgx: `github.com/exaring/otelpgx`
     ```go
     cfg, _ := pgxpool.ParseConfig(dsn)
     cfg.ConnConfig.Tracer = otelpgx.NewTracer()
     pool, err := pgxpool.NewWithConfig(ctx, cfg)
     ```
   - database/sql: `github.com/XSAM/otelsql`
   - go-redis: `github.com/redis/go-redis/extra/redisotel/v9`

5. フレームワークを使っている場合は otelhttp ではなく専用ミドルウェアを使う（`http.route` が自動で付く）
   - chi: `github.com/riandyrn/otelchi`、gin: `go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin`
   - echo: `go.opentelemetry.io/contrib/instrumentation/github.com/labstack/echo/otelecho`

6. 複数サービスを順に呼ぶ処理（請求の確定、注文の確定、アカウントの有効化など）には、業務の識別子とステップを span に付ける

   otelhttp が作るサーバースパンに属性と event を足すだけで、新しい span は作らない。
   ログに出している識別子（`invoice_id` など）と同じ値を属性にしておくと、ログの 1 行からトレースへ、トレースの 1 スパンから他サービスのログへ辿れる。
   以下は SaaS の請求確定（請求を発行 → 決済を依頼 → 支払い済みにする）の例。名前はアプリのエンティティに合わせる。

   ```go
   import (
       "go.opentelemetry.io/otel/attribute"
       "go.opentelemetry.io/otel/codes"
       "go.opentelemetry.io/otel/trace"
   )

   span := trace.SpanFromContext(ctx)
   span.SetAttributes(attribute.String("invoice.id", inv.ID), attribute.Int("invoice.amount_cents", inv.AmountCents))
   // ステップの区切りは event にする（どこまで進んで止まったかがウォーターフォールの時刻で分かる）
   span.AddEvent("invoice.issued")
   span.AddEvent("payment.requested", trace.WithAttributes(attribute.String("payment.provider", provider)))
   span.AddEvent("invoice.paid")
   // 失敗時: 理由を属性と status に残す（下流のクライアントスパンは自動で ERROR になるが、親の理由は自分で書く）
   span.SetAttributes(attribute.String("billing.failure_reason", be.Code))
   span.SetStatus(codes.Error, be.Code)
   ```

   属性名は `<entity>.<field>`（`invoice.id`、`account.id`、`payment.id`）、event 名は `<entity>.<state>`。ユーザー ID のような高カーディナリティでも span 属性なら問題ない（メトリクスの属性には入れない）。

ハンドラ内のログは `slog.InfoContext(r.Context(), ...)` にすると trace_id / span_id が付く（`slog.Info` だと付かない）。

## 重要: `http.route` を自前で付ける理由

`otelhttp` v0.72 は `ServeMux` の `r.Pattern` を **スパン名とメトリクスには使うが、スパン属性 `http.route` は付けない**。
その状態だと Mackerel APM のルート別集計が `/items/abc` のように実パスごとに分かれる。
`assets/go/otel.go` の `withRouteAttribute` がルーティング後に属性を付けて解決する（検証済み）。

## 確認方法

- `go vet ./... && go build ./...` が通る
- Collector に `telemetry.sdk.language=go` の ResourceTraces / ResourceMetrics が届く
- Mackerel の `GET /api/v0/apm/http-server-stats` で `route` が `/items/{id}` のようなテンプレートになる

## 出るテレメトリー（確認済み: otelhttp v0.72 / otelpgx v0.12）

- トレース: サーバースパン `GET /items/{id}`、クライアントスパン `HTTP GET`、SQL スパン（`SELECT` / `INSERT` / `pool.acquire`）
- メトリクス: `http.server.request.duration`（秒）、`http.client.request.duration`、`db.client.operation.duration`

## よくある詰まり

| 症状 | 原因と対処 |
|---|---|
| `undefined: otelhttp.WithRouteTag` | 旧 API。v0.72 以降は不要（Pattern から自動） |
| ログの trace_id が null | ミドルウェアが `instrumentHTTP` の外側、または `ctx` 無しの `slog.Info` |
| スパンが各サービスで分断される | クライアントに `otelhttp.NewTransport` を使っていない、または `SetTextMapPropagator` 漏れ |
| go.sum の不整合 | `go mod tidy` を実行する（手で編集しない） |
| 下流がタイムアウトしたのに、下流側のスパンは OK で終わっている | 呼び出し側のクライアントスパンだけ ERROR（deadline exceeded）になる。これは計装の問題ではなく、下流が処理を完了した後に応答が間に合わなかったことを示す。手順 6 の event と属性で「どのステップまで進んだか」を残しておくと切り分けが速い |
