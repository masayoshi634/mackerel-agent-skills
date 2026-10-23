# Node.js の計装（ゼロコード）

対象: Express / Fastify / Koa / Hono / Next.js など。`@opentelemetry/auto-instrumentations-node` が
HTTP・主要フレームワーク・DB クライアント（pg, mysql2, ioredis, redis, mongodb など）を自動で計装する。
**アプリのコードは変更しない。** 変更するのは依存と起動コマンドだけ。

## 手順

1. 依存を追加する（`dependencies` に入れる。本番でも動かすため）

   ```json
   "@opentelemetry/api": "^1.9.0",
   "@opentelemetry/auto-instrumentations-node": "^0.60.0"
   ```

2. lockfile を更新する。Dockerfile が `npm ci` なら lockfile が古いとビルドが失敗する。
   ホストに Node がなければコンテナで更新する:

   ```bash
   docker run --rm -v "$PWD:/app" -w /app node:24-alpine npm install --package-lock-only --no-audit --no-fund
   ```

   pnpm / yarn の場合はそれぞれ `pnpm install --lockfile-only` / `yarn install --mode update-lockfile`。

3. 起動コマンドにフラグを足す（Dockerfile の `CMD` と `package.json` の `scripts.start` の両方）

   - **CommonJS**（`"type": "module"` がない）:
     `node --require @opentelemetry/auto-instrumentations-node/register server.js`
   - **ESM**（`"type": "module"`、または `.mjs` / TypeScript を ESM で実行）:
     `node --experimental-loader=@opentelemetry/instrumentation/hook.mjs --import @opentelemetry/auto-instrumentations-node/register server.js`

   > ESM で `--import register` だけにすると **http しか計装されず**、スパン名が `GET` / `POST` だけになり
   > `http.route` も付かない（Express のルートが取れない）。必ずローダーフックを併用する。
   > `NODE_OPTIONS` で渡してもよい。

4. compose の environment に `<<: *otel-env` と `OTEL_SERVICE_NAME: <name>` を追加する（`assets/compose.otel.snippet.yaml`）。

5. **SIGTERM でサーバーを閉じる処理を入れる（必須）。** `register` は `process.on('SIGTERM', sdk.shutdown)` を登録する。
   ハンドラが 1 つでもあると Node の既定の「SIGTERM で即終了」が無効になり、`listen` 中のサーバーが残って
   `docker stop` の猶予（既定 10 秒）後に SIGKILL（exit 137）される。アプリに終了処理が無ければ次を足す:

   ```ts
   const server = app.listen(PORT, ...);
   for (const sig of ["SIGTERM", "SIGINT"] as const) {
     process.on(sig, () => {
       server.close();                                   // 新規接続を止める。SDK の flush 後にループが空になれば自然終了
       setTimeout(() => process.exit(0), 5000).unref();  // 念のための打ち切り
     });
   }
   ```

   Fastify / Koa / NestJS なら各フレームワークの `close()` / `app.close()` を同じ場所で呼ぶ。
   compose 側は `depends_on: otel-collector` も必須（`assets/compose.otel.snippet.yaml`）。無いと停止時に Collector が先に消えて export エラーがログに残る。

## 必ず入れる環境変数（x-otel-env に含まれる）

| 変数 | 理由 |
|---|---|
| `OTEL_METRIC_EXPORT_TIMEOUT=5000` | `OTEL_METRIC_EXPORT_INTERVAL` を既定 timeout（30000）より短くすると SDK が **初期化に失敗して黙る**（`exportIntervalMillis must be greater than or equal to exportTimeoutMillis`）。`OTEL_LOG_LEVEL=debug` で初めて見える |
| `OTEL_SEMCONV_STABILITY_OPT_IN=http` | メトリクス名を `http.server.request.duration`（秒）に統一する。これがないと `http.server.duration`（ms）になり他言語と揃わない |
| `OTEL_NODE_DISABLED_INSTRUMENTATIONS=fs,dns,net` | 起動時の fs スパン等のノイズを抑える（Mackerel 公式ガイドも fs を無効化している） |

## ログ（フェーズ 2''）

自動計装は `pino`（v7 以降）と `winston` のログを trace_id 付きで OTel に送る。**`console.log` は送られない。**
`console.log` のアプリでログも送りたい場合は pino への置換（`logger.info({...}, msg)`）を、フェーズ 1 で「送る（`console.log` を pino に置換）」が選ばれたときだけ行う。詳細は `references/logs.md`。

## 確認方法

- `docker compose logs <service>` に SDK のエラーが出ていないこと（出ない＝正常。詳細は `OTEL_LOG_LEVEL=debug`）
- Collector 側で `telemetry.sdk.language=nodejs` の ResourceMetrics が届くこと（届かなければ上の timeout を疑う）
- スパン名が `POST /api/items` のようにルート付きになっていること（`GET` だけならローダーフック漏れ）

## 出るテレメトリー（確認済み: auto-instrumentations-node 0.60 / sdk 2.0）

- トレース: `http` サーバー/クライアント、`express` の middleware / request handler スパン、DB クライアント
- メトリクス: `http.server.request.duration`、`http.client.request.duration`、`nodejs.eventloop.*`、`v8js.*`
- ヘルスチェック（`/healthz`）も含まれる。環境変数では除外できないので、ダッシュボードの PromQL で `http.route!="/healthz"` を付ける

## よくある詰まり

| 症状 | 原因と対処 |
|---|---|
| `npm ci` が `package-lock.json` 不整合で失敗 | 手順 2 の lockfile 更新を忘れている |
| スパン名が `GET` / `POST` だけ | ESM なのにローダーフックがない。手順 3 を見直す |
| メトリクスだけ届かない | `OTEL_METRIC_EXPORT_TIMEOUT` を設定していない |
| `docker compose stop` で Node のサービスだけ 10 秒かかり exit 137 | 手順 5 の SIGTERM 処理がない（`register` のハンドラで既定の終了が無効になる） |
| Node 26 以降で `module.register()` の非推奨警告 | 警告のみで動作する。将来 `--experimental-loader` が廃止されたら `module.registerHooks` 対応版の instrumentation に更新する |
