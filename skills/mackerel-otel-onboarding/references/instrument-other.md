# その他の言語

一級サポート外の言語でも、方針は同じ: **SDK か自動計装エージェントを入れ、標準の `OTEL_*` 環境変数で Collector に送る。**
`x-otel-env` の環境変数はそのまま使える。言語固有の手順は Mackerel 公式ヘルプを参照する
（公式ヘルプは「トレースのみ・Mackerel 直送」の構成なので、エンドポイントとヘッダは Collector 向けに読み替える）。

| 言語 | 推奨手段 | 参考 |
|---|---|---|
| Ruby (Rails/Sinatra) | `opentelemetry-sdk` + `opentelemetry-instrumentation-all`、`OpenTelemetry::SDK.configure { |c| c.use_all }` | https://mackerel.io/ja/docs/entry/tracing/installations/ruby |
| Java (Spring 等) | Java agent: `-javaagent:opentelemetry-javaagent.jar`（コード変更なし） | https://mackerel.io/ja/docs/entry/tracing/installations/other-language |
| PHP | `opentelemetry` 拡張 + auto-instrumentation パッケージ | 同上 |
| .NET | `OpenTelemetry.AutoInstrumentation`（環境変数のみ） | 同上 |
| ブラウザ | `@opentelemetry/sdk-trace-web` | https://mackerel.io/ja/docs/entry/tracing/installations/browser |

## 読み替えのルール

- エンドポイント: `http://otel-collector:4318`（OTLP/HTTP）に統一。SDK 側に Mackerel の URL やヘッダは書かない
- `OTEL_SEMCONV_STABILITY_OPT_IN=http` を渡す。対応していない SDK では `http.server.duration`（ms）になることがあるので、
  その場合はダッシュボードの PromQL を `http.server.duration` 系に差し替える（単位も ms）
- メトリクスを出さない SDK の場合は Collector 側で `spanmetrics` connector を使う（`references/collector.md` のプラン B）
