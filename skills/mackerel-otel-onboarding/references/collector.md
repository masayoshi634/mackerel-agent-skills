# Collector の選び方と設定

アプリは全員 `http://otel-collector:4318`（OTLP/HTTP）に送り、Mackerel への送信は Collector が担う。
アプリ側に Mackerel の URL やヘッダを書かないことで、送信先の変更や認証をアプリから切り離す。

## 既定: contrib Collector（メトリクス・トレース・ログ）

`assets/otel-collector.yaml` を `otel/collector.yaml` にコピーする。メトリクスは OTLP/gRPC、トレースとログは OTLP/HTTP（`Accept: */*` 必須）で Mackerel に送る。
`filter/logs` でヘルスチェックを除外し、マスキングとサンプリングの例をコメントで同梱している。

```yaml
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.138.0
    command: ["--config", "/etc/otelcol-contrib/config.yaml"]
    volumes:
      - ./otel/collector.yaml:/etc/otelcol-contrib/config.yaml:ro
    environment:
      MACKEREL_APIKEY: ${MACKEREL_APIKEY:?}
```

## オプション: MDOT（Mackerel 公式ディストリビューション、ログ不要な場合）

- イメージ: `mackerel/otelcol-mackerel:0.2.0`（タグを固定する。experimental で変更が入りやすい）
- 設定: `assets/otel-collector-mackerel.yaml` を `otel/collector.yaml` にコピーしてマウントする（compose の image / command / volumes も合わせて変える）
- **0.2.0 の exporter はログ未対応。** `logs` パイプラインを書くと `telemetry type is not supported` で Collector 自体が起動しない
- API キー: 環境変数 `MACKEREL_APIKEY` を compose から渡す（`${MACKEREL_APIKEY:?}` で未設定なら起動時に止まる）

### 0.2.0 で確認した注意点

| 事象 | 対処 |
|---|---|
| ゼロ設定モード（`--config mackerel:default`）は受信を **127.0.0.1** にバインドする。`OTELCOL_MACKEREL_HOST=0.0.0.0` を渡しても 0.2.0 では効かない | 明示設定で `0.0.0.0:4317/4318` を指定する（assets の設定がそうなっている） |
| exporter のコンポーネント名は **`mackerelotlp`**。README にある `mackerel_otlp` は未リリースの新名で、0.2.0 では `unknown type` になる | assets の設定は `mackerelotlp` を使う。将来版で名前が変わったら両方試す |
| exporter が metrics / traces / logs それぞれの Mackerel エンドポイントとバッチ・圧縮を内部で処理する | batch processor は不要 |
| 起動ログに `Development component. May change in the future.` が出る | 正常。エラーではない |

### 動作確認

```bash
docker compose logs otel-collector | grep -E "Starting (GRPC|HTTP) server|Everything is ready"
# endpoint が [::]:4318 / 0.0.0.0:4318 ならアプリから届く。127.0.0.1 なら設定が効いていない
docker compose logs --since 5m otel-collector | grep -iE "error|failed"   # 何も出なければ送信成功
```

## プラン B: spanmetrics でトレースから RED を作る

SDK がメトリクスを出せない言語（一部の自動計装エージェント）では、contrib の `spanmetrics` connector で
トレースから `traces.span.metrics.duration` 系のメトリクスを生成し、Mackerel に送る。
その場合ダッシュボード・監視の PromQL はメトリクス名を差し替える必要がある（`dashboard-and-monitors.md` 参照）。

## サンプリング

1 リクエストのスパン数は想像より多い（Express middleware、Redis、SQL を含めると 1 注文で 60 スパン超）。
Mackerel の無料枠は月 5M スパン。常時負荷を流すなら `probabilistic_sampler` を有効にする
（`assets/otel-collector.yaml` にコメントで同梱）。
メトリクスはサンプリングの影響を受けないので、RED の精度は落ちない。

## ローカルで中身を見たいとき

Mackerel に送る前に何が出ているか確認するには、contrib に `debug` exporter（`verbosity: normal`）を付けて
`docker compose logs otel-collector` を読む。メトリクス名・属性・スパン名がそのまま出る。
