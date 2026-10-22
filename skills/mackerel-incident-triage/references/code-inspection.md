# コードの確認（フェーズ 4）

トレースとログで「どこで・なぜ」まで分かったら、その原因を **コードの行** に落とす。恒久対策を「冪等キーを入れる」のような一般論で終わらせず、
「`service.go:127-132` の決済呼び出しに `order_ref` を冪等キーとして渡す」のように書くためのフェーズ。
**コードは変えない**（不変条件）。読んで `file:line` を示すだけ。実装は別の作業として依頼を受ける。

## 1. コードの場所を決める

優先順:

1. `--repo PATH` の指定があればそこ
2. カレントディレクトリが git リポジトリならそこ（`git rev-parse --show-toplevel`）
3. どちらも無ければユーザーに聞く。手元に無い場合は **「コードを特定できない」と報告に書く**（推測で行を書かない）

## 2. サービス名とディレクトリを対応づける

`service.name`（トレースと監視ルールに出る名前）から、そのサービスのコードがあるディレクトリを決める。

| 構成 | 決め方 |
|---|---|
| docker compose | `docker compose config --format json` の `services.<name>.build.context`。`OTEL_SERVICE_NAME` が compose にあればその値で引く |
| モノレポ（`services/<name>` など） | サービス名と同名のディレクトリを探す: `find . -maxdepth 3 -type d -name '<name>'` |
| 1 サービス 1 リポジトリ | リポジトリ全体 |
| 決まらない | `grep -rl 'OTEL_SERVICE_NAME\|service.name' --include='*.yaml' --include='*.yml' --include='*.env*' --include='*.ts' --include='*.go' --include='*.py'` で設定箇所から辿る。それでも無ければユーザーに聞く |

対応表を報告に載せる（例: `checkout → services/checkout`）。

## 3. 証拠から行を探す（パターン別）

証拠（ログ本文、属性、タイムアウト値）を **そのまま grep する**。語を言い換えない。`grep -rn` の結果の `file:line` をそのまま使う。

| 証拠 | grep するもの | 見つかる行が答えるもの |
|---|---|---|
| ログ本文（`payment response timed out; order left pending`） | 本文の固定部分（変数を除いた 3〜5 語）: `grep -rn 'response timed out' <dir>` | そのログを出している行 = 失敗を検知した場所。前後 20 行で「何をして、何をしなかったか」が分かる |
| `failure_reason` / `error.type` / `error` 属性の値（`payment_timeout`） | 値そのもの: `grep -rn 'payment_timeout' <dir>` | その理由を返す分岐 = 失敗の分類が決まる場所 |
| 失敗したルート（`POST /checkout`） | ルート文字列: `grep -rn '"/checkout"\|/checkout' <dir>` | ハンドラの入口。そこから処理の順序を追う |
| タイムアウト（client span が 5001 ms で error） | 言語別の設定: Go `Timeout:` / `context.WithTimeout(`、Node `AbortSignal.timeout(` / `timeout:`、Python `timeout=` / `wait_for(`、Java `connectTimeout` / `readTimeout` | 呼び出し側のタイムアウト値と、リトライの有無 |
| 呼ばれた側が完了してから応答している（`server_finished_after_client`） | 呼ばれた側のハンドラで、結果を確定する行（`INSERT` / `save` / `record` / `captured`）と応答を返す行（`res.json` / `writeJSON` / `return`）の順序 | 「確定してから応答する」順序 = タイムアウト後に結果が残る構造的な原因 |
| 照合ログ（`reconcile: inconsistency found`） | 本文: `grep -rn 'inconsistency found' <dir>`、復旧手段: `grep -rn 'admin/\|reconcile\|repair' <dir> Makefile` | 照合ジョブの実装と、復旧の API / コマンド（止血の手順に使う） |
| DB エラー（`status.message`） | メッセージの固定部分、クエリの一部（`db.query.text` の先頭）、接続プールの設定（`pgxpool` / `pool_size` / `max_connections`） | 失敗するクエリと、プール・タイムアウトの設定 |
| 遅いルート（p95 が大きい） | ルートのハンドラ、その中の外部呼び出しとループ | N+1、直列の外部呼び出し |

言語別の補足:

- Go: `grep -rn` の対象は `*.go`（`_test.go` を除く）。ログは `slog.*` / `log.*`、HTTP は `net/http` と `http.Client`
- Node / TypeScript: `src/` 配下。ログは `pino` / `winston` / `console`、HTTP は `fetch` / `axios` / `got`
- Python: ログは `logging` / `structlog`、HTTP は `httpx` / `requests`
- Java / Kotlin: ログは `logger.*`、HTTP は `RestTemplate` / `WebClient` / `OkHttp`

## 4. 「原因箇所」表にまとめる

報告の「原因」と「恒久対策」に添える表。行は 2〜5 件に絞る（直接原因の行、構造的な原因の行、止血に使う復旧手段の行）。
`file:line` は **GitHub のパーマリンク**（`https://github.com/<owner>/<repo>/blob/<sha>/<path>#L<start>-L<end>`、SHA は push 済みのコミット）にする。取り方は `references/report-format.md` の「リンクの作り方」。

例はデモアプリ [mackerel-otel-demo](https://github.com/masayoshi634/mackerel-otel-demo)（EC サイト、決済の応答遅延で課金済み・注文なしが起きる障害）での調査結果。

| 箇所（`file:line`） | 何をしている | なぜ原因か / 何を変えるか |
|---|---|---|
| `services/checkout/main.go:55` | `http.Client{Timeout: 5 * time.Second}` で決済を呼ぶ | 呼ばれた側の遅延が 5 秒を超えるとタイムアウト。リトライなし |
| `services/payment/src/server.ts:80-86` | 課金を台帳に記録（`captured`）してから応答する | タイムアウト後も課金が残る（構造的な原因）。応答前に冪等キーで引けるようにする |
| `services/checkout/service.go:127-132` | タイムアウトを `payment_timeout` として注文を pending のまま残す | 結果不明の失敗。補償処理（void）か照合で回収する |
| `services/checkout/reconcile.go:106` / `Makefile: reconcile` | 照合と復旧 | 止血の手順に使う |

書き方の規則:

- 行番号は grep の結果をそのまま使う。範囲は `start-end`。推測で書かない。リンクの SHA とファイルの内容が一致すること（未 push の変更を見ているなら、既定ブランチの SHA で行番号を取り直す）
- 「なぜ原因か」は証拠（トレースの ms、ログ本文）と結びつける。「〜の可能性」は推測と明記する
- 該当するコードが見つからなかった証拠は「見つからなかった（grep: `<語>`）」と書く。無いことも情報
- コードが手元に無い場合、この表は省略し、報告の「恒久対策」に「コードを特定できないため一般論」と書く

## 5. 止血の手順をコードから探す

止血は「設定を戻す」「復旧手段を実行する」のどちらかになることが多い。推測で書かず、リポジトリから手段を探す:

- 直近の変更: `git log --since='<発生時刻の 1 日前>' --oneline -- <dir>`。アラートの発生時刻の直前にデプロイや設定変更があれば第一候補
- 設定値: 環境変数や compose の `environment`（タイムアウト、レート、フラグ）。異常な値が入っていれば戻す
- 復旧手段: `admin` / `reconcile` / `repair` / `retry` のルート、Makefile や `scripts/` のターゲット。見つかればそのコマンドを止血の手順に書く
- 見つからなければ「復旧手段はリポジトリに見つからない。手動で <データ> を手当てする必要がある」と書く
