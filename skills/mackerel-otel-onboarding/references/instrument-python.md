# Python の計装（ゼロコード）

対象: FastAPI / Flask / Django / Starlette / aiohttp など。`opentelemetry-instrument` コマンドで起動をラップすると、
インストール済みの instrumentation パッケージが自動で適用される。**アプリのコードは変更しない。**

## 手順

1. 依存を追加する（requirements.txt / pyproject）。`opentelemetry-bootstrap -a install` で自動検出させてもよいが、
   Docker ビルドの再現性のため **使っているライブラリの instrumentation を明示する** のを推奨する。

   ```
   opentelemetry-distro
   opentelemetry-exporter-otlp-proto-http
   opentelemetry-instrumentation-fastapi      # FastAPI の場合（Flask なら -flask、Django なら -django）
   opentelemetry-instrumentation-redis        # 使っている DB/クライアントに合わせて
   opentelemetry-instrumentation-psycopg      # psycopg3 / psycopg2 / sqlalchemy / httpx / requests など
   ```

   何が必要か分からなければ、一時的にコンテナ内で `opentelemetry-bootstrap -a requirements` を実行すると候補が出る。

2. 起動コマンドを `opentelemetry-instrument` でラップする（Dockerfile の `CMD`）

   ```
   CMD ["sh", "-c", "opentelemetry-instrument uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
   ```

   - gunicorn の場合はワーカーごとに初期化が必要。`opentelemetry-instrument gunicorn ...` で動くが、
     `--preload` は使わない（fork 後に exporter が動かなくなる）
   - `--reload` は使わない

3. compose の environment に `<<: *otel-env` と `OTEL_SERVICE_NAME: <name>` を追加する。
   FastAPI / Starlette はヘルスチェックを除外できる: `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS: healthz`
   （Flask は `OTEL_PYTHON_FLASK_EXCLUDED_URLS`、Django は `OTEL_PYTHON_DJANGO_EXCLUDED_URLS`）

## ログ（フェーズ 2''）

`OTEL_LOGS_EXPORTER=otlp` にすると stdlib `logging` と uvicorn のログが trace_id 付きで送られる（`OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true`、SDK 1.40 以降は既定）。コード変更なし。詳細は `references/logs.md`。

## 確認方法

- 起動ログに `opentelemetry` のエラーがないこと
- Collector に `telemetry.sdk.language=python` の ResourceTraces / ResourceMetrics が届くこと
- スパン名が `GET /carts/{cart_id}` のようにルートテンプレートになっていること

## 出るテレメトリー（確認済み: instrumentation-fastapi 0.66b0）

- トレース: ASGI の server / receive / send スパン、Redis コマンド（`HGETALL` など）
- メトリクス: `http.server.request.duration`（秒）、`http.server.active_requests`、`http.server.request/response.body.size`
- スパン属性に `http.route` が付くので Mackerel APM のルート別集計はそのまま効く

## よくある詰まり

| 症状 | 原因と対処 |
|---|---|
| 計装はされるがメトリクス名が `http.server.duration` | `OTEL_SEMCONV_STABILITY_OPT_IN=http` が渡っていない |
| Django でスパンが出ない | `DJANGO_SETTINGS_MODULE` が `opentelemetry-instrument` 実行時に見えていない |
| 一部ライブラリが計装されない | その instrumentation パッケージが未インストール。手順 1 を見直す |
