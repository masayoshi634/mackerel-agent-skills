# ビジネスメトリクス（任意フェーズ）

技術指標（RED）だけのダッシュボードは、監視に慣れていない人には「で、うまくいってるの？」が分からない。
コードから **ドメインの成功イベント** を見つけてカウンタを 2〜3 個足すと、ダッシュボードが「事業の計器盤」になる。
これはコード変更を伴うので、フェーズ 1 の一括確認で候補を示し、選ばれたものだけ入れる。候補は AskUserQuestion の multiSelect の選択肢になるので **最大 3 個** に絞る（選択肢は「追加しない」を含めて 4 個まで）。

**このファイルの例の名前をそのまま使わない。** メトリクス名はアプリのログとコードにある語（エンティティとイベント）から付ける。
例は業種が違っても同じパターンになることを示すためのもの。

## 足す 3 つのパターン

| パターン | 何を数えるか | EC の例 | SaaS の例 | バッチ / ジョブの例 |
|---|---|---|---|---|
| 成功イベントのカウンタ | 事業上の「できた」 | `shop.orders.created`、`shop.payments.captured` | `saas.signups.completed`、`saas.plans.upgraded` | `jobs.imports.completed`、`mail.messages.sent` |
| 理由別の失敗カウンタ | 「できなかった」と理由（`reason` 属性） | `shop.orders.failed{reason}` | `saas.signups.failed{reason}` | `jobs.imports.failed{reason}` |
| 不変条件のゲージ | 「今、壊れた状態がいくつあるか」 | 課金済みなのに注文が無い件数 | 請求済みなのに有効化されていないアカウント数 | 期限を過ぎても終わっていないジョブ数 |

金額があれば売上や請求額のカウンタ（単位は通貨コード）も候補になる。

## 見つけ方

- 成功イベント: ログに `created` / `completed` / `captured` / `sent` / `activated` と出ている場所。多くは「保存して 200 を返す」直前
- 失敗: 成功と同じ関数の `return err` や `catch`。失敗の種類が分かる `code` / `reason` 変数があれば属性にする
- 不変条件: 定期実行の goroutine / ジョブ / cron で `reconcile` / `audit` / `drift` / `stale` / `orphan` / `inconsistency` のような語をログに出している場所。
  件数を保持する構造体やメソッド（直近の結果を返す `Last()`、`Report()`、`Status()`）があれば、それをコールバックで読む

## 命名規約

- `<domain>.<entity>.<event>`: domain はアプリやサービスの文脈（`shop`、`saas`、`jobs`）、entity は数える対象、event は起きたこと
- 単位: 件数は `{order}` `{signup}` `{job}` のような注釈単位、金額は `JPY` / `USD`
- 属性は **低カーディナリティ** のものだけ（`reason`、`plan`、`provider`、`job_type`）。ユーザー ID や注文 ID のような一意の値は入れない（span 属性に入れる）

## 最小コード

### Go（SaaS のサインアップ）

```go
meter := otel.Meter("account")
signups, _ := meter.Int64Counter("saas.signups.completed", metric.WithUnit("{signup}"))
signupsFailed, _ := meter.Int64Counter("saas.signups.failed", metric.WithUnit("{signup}"))
// 成功時
signups.Add(ctx, 1, metric.WithAttributes(attribute.String("plan", plan)))
// 失敗時
signupsFailed.Add(ctx, 1, metric.WithAttributes(attribute.String("reason", code)))
```

### Node（バッチの完了。自動計装と併用し、`@opentelemetry/api` だけで書ける）

```ts
import { metrics } from "@opentelemetry/api";
const meter = metrics.getMeter("importer");
const completed = meter.createCounter("jobs.imports.completed", { unit: "{job}" });
completed.add(1, { job_type: jobType });
```

### Python（EC のカート）

```python
from opentelemetry import metrics
meter = metrics.get_meter("cart")
items_added = meter.create_counter("shop.cart.items_added", unit="{item}")
items_added.add(quantity)
```

## 不変条件の照合結果はゲージにする

カウンタは「起きたこと」を数える。それとは別に、**「今、壊れている状態がいくつあるか」** を表す数字がコードにあれば、それはゲージにする。
複数サービスを順に呼ぶ処理（分散トランザクション）や、外部サービスと状態を同期する処理を持つアプリでは、照合ジョブが
「相手側では完了しているのに自分側に記録が無い」「予約だけ残っている」「期限を過ぎても終わっていない」のような不整合を定期的に数えていることが多い。
この数は 5xx や p99 には現れないので、ゲージにして監視ルールを付けないとアラートにならない。

### Go（ObservableGauge。値はコールバックで読むので、計測のためのコードは呼び出し側に要らない）

```go
meter := otel.Meter("importer")
_, _ = meter.Int64ObservableGauge("jobs.imports.stale",
    metric.WithUnit("{job}"),
    metric.WithDescription("期限を過ぎても完了していないインポートジョブの件数（照合ジョブの直近の結果）"),
    metric.WithInt64Callback(func(_ context.Context, o metric.Int64Observer) error {
        if r := checker.Last(); r != nil {
            o.Observe(int64(len(r.Stale)))
        }
        return nil
    }))
```

- 直近の結果が無い間は `Observe` しない（0 を入れると「照合できていない」と「不整合なし」が区別できなくなる）
- 不整合の種類が複数あるなら、属性 `kind` で分けるよりメトリクス名を分ける（`jobs.imports.stale` と `jobs.imports.orphaned`）方が監視ルールが書きやすい

### 失敗カウンタの `reason` は「分かっている失敗」と「結果不明」を分ける

`<domain>.<entity>.failed{reason}` の `reason` は、相手が明示的に拒否した（`rejected`、`validation`）のか、応答が無くて結果が分からない（`timeout`）のかを分ける。
後者だけが不整合を生むので、ダッシュボードで理由別に並べると「失敗が増えた」ではなく「不整合が増えているかもしれない」まで読める。

## 監視ルールとダッシュボードへの追加

ゲージと失敗カウンタには `scripts/create-monitors.sh --extra` で監視を付ける（形式と再実行時の扱いは `references/dashboard-and-monitors.md`）:

```bash
scripts/create-monitors.sh --extra "stale imports|max(jobs.imports.stale)||0" \
                           --extra "signup timeouts / 5m|sum(increase(saas.signups.failed{reason=\"timeout\"}[5m]))|1|5"
```

`warn|crit` のどちらかは空にできる。上の 1 つ目は「1 件でもあれば CRITICAL」。

成功と失敗を並べたグラフは `scripts/create-dashboard.sh --extra` で足す:

```bash
scripts/create-dashboard.sh --extra "サインアップ数 / 5m|sum(increase(saas.signups.completed[5m]))|signups" \
                            --extra "失敗（理由別） / 5m|sum by (reason) (increase(saas.signups.failed[5m]))|{{reason}}" \
                            --extra "期限超過のジョブ|max(jobs.imports.stale)|stale"
```

成功イベントを 2 つ並べる（例: 決済成功数と注文数、請求数と有効化数）と「片方は増えているのにもう片方が増えない」が 1 画面で見える。

## Mackerel での名前

Counter（Sum 型）もゲージも Mackerel では **元の名前のまま**（`saas.signups.completed`）保存される。
サフィックス `.count` / `.sum` / `.p99` が付くのはヒストグラムだけなので付けない（実機確認済み）。`increase()` / `irate()` はそのまま使える。
