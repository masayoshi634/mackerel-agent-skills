# ダッシュボードと監視ルールの既定

## メトリクスの前提

全言語の HTTP サーバー計装が出す `http.server.request.duration`（ヒストグラム、単位: 秒）を使う。
Mackerel ではラベル付きメトリックとして次の名前で参照できる:

| 名前 | 意味 |
|---|---|
| `http.server.request.duration.count` | リクエスト数（累積カウンタ） |
| `http.server.request.duration.p99` / `.p95` / `.p90` | レイテンシのパーセンタイル（秒） |
| `http.server.request.duration.sum` / `.max` / `.min` | 合計・最大・最小（秒） |

ラベル: `service.name`、`http.request.method`、`http.route`、`http.response.status_code`（他に `url.scheme` 等）。
ヘルスチェックのルートは除外する。除外ルートは `discover.sh` が compose のヘルスチェックから検出し（`exclude_routes`。見つからなければ `/healthz`）、
監視ルールとダッシュボードの両方が自動で使う（1 つなら `http.route!="/healthz"`、複数なら `http.route!~"(/healthz|/readyz)"`）。`--exclude-routes` で上書きできる。

## ダッシュボード（`scripts/create-dashboard.sh`、監視ルールの後に実行）

サービスごとに 1 行、3 枚の query グラフ。参考線と見出しの SLO 表は **同じ接頭辞の監視ルールから読む** ので、監視ルールの後に実行する。
更新時は RED の行だけ作り直し、以前 `--extra` で足したグラフは並びを保ったまま残す。

| グラフ | PromQL（S = サービス名） | 凡例 |
|---|---|---|
| Requests / 5m | `sum by (http.route) (increase(http.server.request.duration.count{service.name="S",<除外>}[5m]))` | `{{http.route}}` |
| 5xx errors / 5m | `sum(increase(...count{service.name="S",...}[5m])) - sum(increase(...count{service.name="S",...,http.response.status_code!~"5.."}[5m]))` | `5xx` |
| p99 latency (ms) | `max by (http.route) (http.server.request.duration.p99{service.name="S",<除外>}) * 1000` | `{{http.route}}` |

**エラー率(%)は作れない。** Mackerel の PromQL はベクトル同士の除算 `/` に対応していない（`on()` / `by` / `scalar()` を使っても「データが存在しません」になることを実機確認した。`+` `-` `* <定数>` と比較演算は動く）。
そのため 5xx を「全体 − 非5xx」の **件数** で出す。5xx 専用セレクタ（`status_code=~"5.."`）だと 5xx が 0 件の期間に系列が存在せず空になるが、引き算なら 0 が描ける。

ビジネスメトリクスを追加した場合は `--extra "タイトル|PromQL|凡例"` で足す（一度足せば再実行しても残る）:

```bash
scripts/create-dashboard.sh --extra "サインアップ数 / 5m|sum(increase(app.signups.completed[5m]))|signups" \
                            --extra "失敗（理由別） / 5m|sum by (reason) (increase(app.signups.failed[5m]))|{{reason}}"
```

> OTel の Counter（Sum 型）は **元の名前のまま**（サフィックスなし）で保存される（実機確認済み）。`.count` や `.sum` が付くのはヒストグラムだけ。
> `increase()` / `irate()` はそのまま使える。

## 監視ルール（`scripts/create-monitors.sh`）

| ルール名 | クエリ | しきい値 | 根拠 |
|---|---|---|---|
| `[otel-onboarding:<project>] S 5xx errors` | 5xx 件数の式（上と同じ、1 系列） | `--svc` で SLO から翻訳（`references/slo.md`）。未指定なら既存値、初回は warn 10 / crit 50（件/5分） | 率が使えないため件数。トラフィックが多いサービスは引き上げる |
| `[otel-onboarding:<project>] S p99 latency` | `max(http.server.request.duration.p99{service.name="S",<除外>}) * 1000` | 同上。初回は warn 1000ms / crit 2000ms | 呼び出し元のタイムアウトと体感限界から決める |
| `[otel-onboarding:<project>] external <project>`（`--public-url` 指定時のみ） | 外形監視 | 応答 1s / 3s | ローカル環境では使えない |
| `[otel-onboarding:<project>] <名前>`（`--extra` 指定時のみ） | 任意の PromQL | 引数で指定 | ビジネスメトリクスや不変条件のゲージ用（下記） |

- 接頭辞にプロジェクト名が入るので、同じ組織で複数のアプリに適用しても互いのルールを消し合わない（v0.2 以前は `[otel-onboarding]` 固定だった。残っていれば `teardown.sh --prefix "[otel-onboarding]" --monitors-only` で消す。`--monitors-only` が無いとダッシュボードも消える）
- `evaluateBackwardMinutes` 既定 1（瞬間値のブレで鳴らない）、`notificationInterval` 60 分
- **再実行で何も勝手に消えない。** 同名ルールは更新、指定しなかったしきい値と memo は既存の値を保つ。削除されるのは RED のルール名の形で compose から消えたサービスのものだけで、`--extra` と外形監視は削除しない
- `--svc "S|err=warn/crit|p99=warn/crit|slo=...|note=..."` の `slo` / `note` は memo に書かれ、Mackerel の画面と `report.sh` で根拠が読める
- 通知先の設定（Slack 等）はスコープ外。Mackerel の既定通知グループに入る

ビジネスメトリクスや不変条件のゲージ（`references/business-metrics.md`）には `--extra "名前|PromQL|warn|crit[|演算子]"` で監視を足す。名前には接頭辞が付き、同名なら更新:

```bash
scripts/create-monitors.sh --extra "stale jobs|max(app.jobs.stale)||0" \
                           --extra "timeouts / 5m|sum(increase(app.requests.failed{reason=\"timeout\"}[5m]))|1|5"
```

`warn` と `crit` のどちらかは空にできる（上の 1 つ目は crit だけ。1 件でもあれば CRITICAL）。演算子は `>`（既定）か `<`。
一度作れば次回以降の再実行で `--extra` を省いても残る（消したいときは Mackerel の画面か `teardown.sh`）。

## プラン B（spanmetrics）のときの差し替え

`traces.span.metrics.calls.count` / `traces.span.metrics.duration.p99` のような名前になる。
ラベルは `service.name`、`span.name`、`status.code`。エラー率は `status.code="STATUS_CODE_ERROR"` で数える。
