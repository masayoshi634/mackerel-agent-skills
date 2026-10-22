# トラブルシューティング

| 症状 | 見るところ | 原因と対処 |
|---|---|---|
| preflight で 401/403 | API キー | Write 権限のキーか、組織が合っているか。キー変更は反映に 1 分程度 |
| アプリは動くが Collector に何も届かない | `docker compose logs otel-collector` の `Starting HTTP server` の endpoint | `127.0.0.1` なら Collector がループバックにバインドしている。明示設定で `0.0.0.0` にする |
| Collector に `unknown type: "mackerel_otlp"` | 同上 | 0.2.0 の名前は `mackerelotlp` |
| Node のスパン名が `GET` / `POST` だけ | Mackerel APM のルート一覧 | ESM なのに `--experimental-loader=@opentelemetry/instrumentation/hook.mjs` がない |
| Node のメトリクスだけ届かない | `OTEL_LOG_LEVEL=debug` で起動 | `exportIntervalMillis must be >= exportTimeoutMillis`。`OTEL_METRIC_EXPORT_TIMEOUT=5000` を足す |
| Node の `npm ci` が失敗 | ビルドログ | 依存追加後に lockfile を更新していない |
| Go で APM のルートが `/items/123` のように分かれる | `http-server-stats` の `route` | スパンに `http.route` がない。`assets/go/otel.go` の `withRouteAttribute` を入れる |
| 言語間でメトリクス名が違う（`http.server.duration` が混ざる） | Collector の debug 出力 | `OTEL_SEMCONV_STABILITY_OPT_IN=http` が一部に渡っていない |
| トレース API が 0 件 | `verify-ingest.sh --namespace` | `service.namespace` を付けているのに API に `serviceNamespace` を渡していない |
| トレースはあるがサービス間で分断 | トレース詳細 | クライアント側の計装漏れ（Go: `otelhttp.NewTransport`、Node/Python: 自動計装の対象ライブラリか） |
| ダッシュボードのグラフが空 | 2 分待つ → メトリックエクスプローラー | メトリクス名のズレ。エクスプローラーで `http.server.request.duration` を検索し、`.count` `.p99` の有無と単位を確認 |
| 監視ルールが鳴らない | 監視ルールの詳細画面 | クエリが 1 系列に集約されているか、`evaluateBackwardMinutes` の分だけ遅れていないか |
| スパンの無料枠を使い切りそう | Mackerel の利用量 | `probabilistic_sampler` を有効にする。負荷試験のクライアントを止める |
| API が `Rate limit exceeded`（HTTP 500） | verify-ingest の出力 | 短時間に叩きすぎ。`--interval` を 15 以上にし、少し待って再実行 |
| トレース API が 400 `range ... 30 minutes` | 同上 | `--since-minutes` が 30 を超えている |
| 比率のグラフ（A/B）が空 | ダッシュボード | Mackerel の PromQL はベクトル除算非対応。件数（A − B）に置き換える |
| p99 のグラフが短い表示範囲（1h）だけ空、6h にすると出る | ダッシュボード | 値が数 ms 以下のサービスで起きる Mackerel 側の描画の挙動。データは届いている。表示範囲を広げるか `.max` を併用する |
| Collector が `telemetry type is not supported` で起動しない | Collector ログ | MDOT でログを送ろうとしている。contrib（既定）に切替 |
| ログの `traceId` が null | `verify-ingest.sh --logs` | Go: ミドルウェアが計装の外側 / `ctx` 無しの slog。Node: `console.log`。起動ログなどリクエスト外は null で正常 |
| Go のログが大量に出続ける | stdout | OTel SDK エラーが slog 経由でループ。テンプレートの `otel.SetErrorHandler` を入れる |
| `docker compose down` のたびに Mackerel のログへ SDK の ERROR/WARN（`Failed to resolve 'otel-collector'` / `Failed to export ... batch`）が残る、停止に 20 秒ほどかかる | `verify-ingest.sh` の `collector_dependency_missing` | アプリが `otel-collector` に `depends_on` していないので Collector が先に止まる。各サービスに `depends_on: { otel-collector: { condition: service_started } }` を追記 |
| `docker compose stop` で Node のサービスだけ 10 秒かかる（exit 137） | `docker inspect` の ExitCode | `auto-instrumentations-node/register` の SIGTERM ハンドラで Node の既定終了が無効化され、サーバーが閉じられない。`references/instrument-node.md` 手順 5 の `server.close()` を入れる |
| 監視ルールが二重にある（`[otel-onboarding] ...` と `[otel-onboarding:<project>] ...`） | 監視ルール一覧 | v0.2 以前の接頭辞のルールが残っている。`scripts/teardown.sh --prefix "[otel-onboarding]" --monitors-only` で古い方だけ消す。**`--monitors-only` を忘れるとダッシュボードも削除される**（urlPath で特定するため接頭辞に関係ない。消えても `create-dashboard.sh --extra ...` で再生成できる） |
| 再実行したら SLO で決めたしきい値が既定値に戻った | `create-monitors.sh` の引数 | `--error-*` / `--p99-*` は全サービス一括の上書き。サービス別に変えるときは `--svc "S|p99=1200/1500"` のように差分だけ渡す |
| ヘルスチェックのルートが Requests のグラフに出る | `discover.sh` の `exclude_routes` | compose の healthcheck から検出できていない（URL が無い形式など）。`--exclude-routes "/healthz,/ready"` を監視・ダッシュボード・verify-ingest に渡し、Go は `OTEL_HTTP_EXCLUDE_PATHS` も合わせる |
| 5xx の監視が少ないトラフィックで鳴りすぎる | 監視ルールの memo | 件数しきい値が下限（warn 2 / crit 5）より小さい。`references/slo.md` の下限を適用し直す |
