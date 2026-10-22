# ログを Mackerel に送る（フェーズ 2''）

Mackerel のログ機能は OTLP でログを受け取り、`service.name` ごとに検索できる。トレースと同じ Collector 経由で送り、
ログに `trace_id` / `span_id` が付くので **アラート → トレース → そのスパンのログ** と辿れる。

## 前提と注意（2026-10 時点）

- ログ機能は 2026-07 オープンβ、正式リリース予定 2026-11-01。β中は仕様変更・保持保証なしの注記あり → 既定 OFF、**承認を得てから有効化**
- **`service.name` がないログは画面に出ない**（SDK 経由なら resource に付くので問題なし）
- 送信先はトレースと同じ `https://otlp-vaxila.mackerelio.com`（`/v1/logs`、`Accept: */*`）。1 リクエスト 3.5MB 上限
- **MDOT 0.2.0 はログ未対応**（logs パイプラインを足すと `telemetry type is not supported` で Collector が起動しない）。contrib を使う（既定の `assets/otel-collector.yaml`）
- 検索 API: `POST /api/v0/logs` `{serviceName, serviceNamespace, from, to, perPage}`（`serviceName` 必須、結果に `traceId` / `spanId` / `severity` / `body` / `attributes` / `cursor`）

## 有効化の手順

1. compose の `x-otel-env` で `OTEL_LOGS_EXPORTER: ${OTEL_LOGS:-none}` の既定を `otlp` に変える（または `.env` に `OTEL_LOGS=otlp`。スキルは `.env` を書かない）
2. Collector 設定に `logs` パイプラインがあることを確認（`assets/otel-collector.yaml` には最初からある）
3. 言語ごとのブリッジ（下表）
4. `docker compose up -d --build` → `scripts/verify-ingest.sh --logs` でサービスごとの到達と `traceId` 付与率を確認

| 言語 | やること | trace_id |
|---|---|---|
| Python | 環境変数のみ（`OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true`、SDK 1.40 以降は既定）。stdlib `logging` と uvicorn のログが送られる | 付く |
| Node | `pino`（v7 以降）または `winston` を使っていれば自動計装が送る。**`console.log` は送られない**。置換はユーザーに提案し、承認時のみ行う | 付く |
| Go | `assets/go/otel.go` の `newLogger()` で `slog` を stdout + OTel に fanout。ハンドラ内は `slog.InfoContext(r.Context(), ...)`。**ログや認証などのミドルウェアは `instrumentHTTP` の内側に置く**（外側だと `trace_id` が null） | 付く |
| その他 | 各言語の OTel ログブリッジ（Java agent は既定で送る、Ruby は `opentelemetry-logs-sdk`） | 言語による |

## 量と内容の制御（Collector 側）

- `filter/logs` でヘルスチェック行を落とす（既定で `/healthz` `/health` `/readyz`）
- DEBUG を落とす: `- 'severity_number < SEVERITY_NUMBER_INFO'`
- マスキング: `transform/mask` の例が `assets/otel-collector.yaml` にコメントで入っている（メール、特定属性の削除）
- 目安: 1 リクエストあたり各サービス 1〜3 行。負荷試験中は時間あたり数万行になるので、試験が終わったら止めるか `filter/logs` で絞る

## 確認方法

```bash
scripts/verify-ingest.sh --logs            # サービスごとの件数と traceId 付与率
```

`traceId` が null のログが多い場合: Go はミドルウェアの順序か `ctx` 無しの `slog.Info`、Node は `console.log`、Python は uvicorn の起動ログ（リクエスト外）が原因。

## よくある詰まり

| 症状 | 原因と対処 |
|---|---|
| Collector が起動しない `telemetry type is not supported` | MDOT でログを送ろうとしている。contrib に切替 |
| Go のログが止まらない / 大量の SDK エラー | OTel の既定エラーハンドラが slog に流れてループ。`otel.SetErrorHandler` で stdout 専用に（テンプレート済み） |
| Mackerel のログ画面に出ない | `service.name` が無い、または API 検索で `serviceNamespace` を渡していない |
| Node のログが 0 件 | `console.log`。pino / winston に置換するか、ログ送信を諦める |
