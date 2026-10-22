---
name: mackerel-otel-onboarding
description: Instrument a docker compose application with OpenTelemetry and start monitoring it in Mackerel using only a MACKEREL_APIKEY. Adds zero-code or SDK instrumentation (Node.js, Python, Go; others via docs), adds an OpenTelemetry Collector that ships metrics, traces and optionally logs to Mackerel, verifies ingestion through Mackerel APIs, proposes per-service SLO targets inferred from the code (service roles, client timeouts, measured baseline) for a one-question approval, then idempotently creates alert monitors, a RED dashboard and a report. Use when the user wants to add monitoring, observability, APM, tracing, metrics or SLO-based alerts to an existing app with Mackerel, mentions Mackerel together with OpenTelemetry/OTel, or says 監視を始めたい / 計装したい / Mackerel に送りたい / ダッシュボードとアラートを作りたい / SLO を決めたい.
license: MIT
compatibility: Requires bash, docker compose v2, curl, jq, and network access to api.mackerelio.com and Mackerel OTLP endpoints. Target app must run with docker compose.
metadata:
  author: masayoshi634
  version: "0.3.0"
---

# Mackerel OpenTelemetry オンボーディング

docker compose で動いている既存アプリに、OpenTelemetry の計装と Mackerel への送信、監視ルール、ダッシュボードを **API キー 1 つで** 整える。
計装の知識がない人が「スキルを実行したら監視が始まっていた」状態になることを目指す。判断（計装方針、SLO の目標、しきい値）はあなた（エージェント）がコードと実測から導き、ユーザーには承認だけを求める。

## 不変条件（必ず守る）

1. **API キーをファイルに書かない。** `MACKEREL_APIKEY` は環境変数（または既にある `.env`）から読むだけ。会話やログにも出さない。
2. **コミットしない。** 変更は作業ツリーに残し、確認はユーザーに委ねる。
3. **計画と diff を見せてから適用する。** 承認ポイントは「計画」「ビジネスメトリクス追加」「ログ送信」「SLO」の 4 回。
4. **Mackerel 上の操作は冪等で、何も勝手に消えない。** ダッシュボードは `urlPath`、監視ルールは名前（接頭辞 `[otel-onboarding:<project>]`）で識別して更新する。再実行で指定しなかったしきい値は今の値を保ち、`--extra` で足した監視ルールとグラフは削除しない。削除されるのは compose から消えたサービスの RED ルールだけ。
5. **scripts/ はリポジトリのファイルを変更しない。** コードと compose の変更は、references に従ってあなたが行う。設定ファイルも持たない（状態は Mackerel と compose にある）。
6. アプリを壊さない。計装の初期化失敗でアプリが落ちない形にする（Go はエラーをログに出して続行、Node/Python はラッパーなので影響なし）。
7. **SLO は「目標の合意 → しきい値への翻訳」まで。** Mackerel の query 監視はしきい値型で、エラー率やバーンレート、30 日の達成率は監視できない（PromQL のベクトル除算非対応）。翻訳の根拠は監視ルールの memo に残す。

## 入力

| 変数 | 必須 | 既定 | 用途 |
|---|---|---|---|
| `MACKEREL_APIKEY` | 必須 | - | Write 権限の API キー |
| `OTEL_DEPLOYMENT_ENV` | 任意 | `local` | `deployment.environment.name`（APM の環境） |
| `OTEL_SERVICE_NAMESPACE` | 任意 | compose のプロジェクト名 | `service.namespace`。API 問い合わせにも同じ値を使う |
| `PUBLIC_URL` | 任意 | なし | 公開 URL があれば外形監視も作る |
| `OTEL_LOGS` | 任意 | `none` | `otlp` でログも送る（フェーズ 2'' で承認されたら compose の既定を変える） |

## 進め方

各フェーズの先頭で「何をするか」を 1〜3 行で伝えてから実行する。スクリプトは `${CLAUDE_SKILL_DIR}`（このスキルのディレクトリ。プラグインとして入れた場合も Claude Code が展開する）基準で実行する。references 内の `scripts/...` も同じく `${CLAUDE_SKILL_DIR}/scripts/...` と読み替える。

### フェーズ 0: 事前確認

```bash
${CLAUDE_SKILL_DIR}/scripts/preflight.sh
```

docker compose / curl / jq、compose の妥当性、API キーの有効性と組織名を確認する。失敗したらメッセージに従って止まる（キー未設定なら発行方法を案内して終了）。

### フェーズ 1: 検出と計画 → 承認 1

```bash
${CLAUDE_SKILL_DIR}/scripts/discover.sh --pretty
```

出力（`references/inventory-format.md`）を読み、次を表にして提示し **承認を得る**:

- 計装対象のサービス（`kind: app`）と言語・フレームワーク、各サービスの変更方針（ゼロコード / ラッパー / コード追加）
- `profiles` 付きや `already_instrumented` のサービスの扱い
- 追加する Collector と compose の共通環境変数、メトリクスから除外するルート（`exclude_routes`。compose のヘルスチェックから検出）
- 作る監視ルールとダッシュボードの一覧。しきい値は「フェーズ 4.5 でコードと実測から SLO を提案する」と予告し、ここでは決めない

言語が `unknown` のサービスがあれば `references/instrument-other.md` を読み、ユーザーに確認する。

### フェーズ 2: 計装

言語ごとの references に **厳密に** 従う。自己流で SDK 設定を書かない。

| 言語 | 読む | 変更するもの |
|---|---|---|
| Node.js | `references/instrument-node.md` | package.json の依存、lockfile、起動コマンド（ESM はローダーフック必須） |
| Python | `references/instrument-python.md` | requirements、起動コマンドを `opentelemetry-instrument` でラップ |
| Go | `references/instrument-go.md` | `assets/go/otel.go` をコピー、main.go に数行、`go mod tidy` |
| その他 | `references/instrument-other.md` | Mackerel 公式ヘルプに従い、送信先だけ Collector に向ける |

共通: `assets/compose.otel.snippet.yaml` の `x-otel-env` を compose に追加し、各サービスに `<<: *otel-env` と `OTEL_SERVICE_NAME` を付ける。
`__PROJECT__` は compose のプロジェクト名に置き換える。`exclude_routes` が `/healthz` 以外なら `OTEL_HTTP_EXCLUDE_PATHS` と Collector の `filter/logs` も合わせる（監視ルールとダッシュボードは自動で同じ除外を使う）。

変更は **サービス単位で diff を見せる**。ビルドが通ることをフェーズ 4 で確認する。

### フェーズ 2': ビジネスメトリクス → 承認 2

`references/business-metrics.md` に従い、コードから成功イベント（注文確定、決済成功など）を 2〜3 個見つけてカウンタ追加を **提案** する。照合バッチや reconciler のように「壊れている状態の件数」を数えているコードがあれば、それはゲージとして提案に含める（5xx にも p99 にも出ない不整合を監視できる唯一の手段）。承認されたら実装し、フェーズ 5 で `--extra` として監視ルールに、フェーズ 6 で `--extra` としてグラフに加える（一度作れば再実行しても消えない）。断られたらスキップする。

### フェーズ 2'': ログ → 承認 3

`references/logs.md` に従い、ログを Mackerel に送るかを **提案** する（β機能のため既定 OFF。保持保証なしの注記を添える）。
承認されたら: compose の `OTEL_LOGS_EXPORTER` の既定を `otlp` にし、Go は `newLogger()` と `InfoContext`、Node は pino/winston の場合のみ（`console.log` なら「送られない」と伝え、置換は別途提案）、Python は環境変数のみ。
断られたら Collector の `logs` パイプラインは残したままでよい（アプリが送らなければ何も流れない）。

### フェーズ 3: Collector

`assets/otel-collector.yaml` を `otel/collector.yaml` にコピーし、`assets/compose.otel.snippet.yaml` の `otel-collector` サービス（contrib）を compose に追加する。**計装する全サービスの `depends_on` に `otel-collector`（`condition: service_started`）を必ず加える**（既存の `depends_on` があれば追記）。これが無いと `docker compose down` で Collector が先に消え、SDK の export エラーが Mackerel のログに残り、停止も遅くなる。フェーズ 4 の verify-ingest が漏れを警告する。
Mackerel 公式ディストリビューション（MDOT）はログ未対応なので、ログを送らない場合のオプション。判断に迷ったら `references/collector.md`。

### フェーズ 4: 起動と到達確認

```bash
docker compose up -d --build
${CLAUDE_SKILL_DIR}/scripts/verify-ingest.sh --hit http://localhost:<port>/ ...   # 入口の URL をいくつか渡してトラフィックを作る
```

- ビルドや起動に失敗したら、そのサービスのログを読んで references の「よくある詰まり」から直す
- verify-ingest は全サービスのトレースが Mackerel API で見えるまで待ち（既定 180 秒）、APM のルート別統計とサービス単位の要約（`baseline`: 5 分換算の件数、エラー率、p95）、Collector のエラーを表示する。`depends_on` に Collector が無いサービスがあれば `collector_dependency_missing` に出るので、compose を直してから次へ進む
- `service.namespace` を変えた場合は `--namespace` を明示する（API に必須）
- ログを有効にした場合は `--logs` を付け、サービスごとの件数と `traceId` 付与率を確認する
- メトリクスは API で確認できない。フェーズ 6 の後にダッシュボードで確認する（反映まで 1〜2 分）

### フェーズ 4.5: SLO の提案 → 承認 4

`references/slo.md` に従い、**あなたがコードと実測から全サービス分を埋めて** 提示し、ユーザーは 1 問に答えるだけにする。

1. 役割を判定する（`entry` / `internal` / `gateway` / `worker`）。discover の `ports`、`depends_on`、`upstream_env` と、コードの HTTP ルートから決める
2. 呼び出し側のタイムアウトとリトライを grep で拾い（言語別パターンは references）、「呼ばれる側の p99 目標 = 呼び出し元タイムアウト ÷ 2」を導く
3. verify-ingest の `baseline` と役割別の初期値から、サービスごとに「役割 / 可用性の目標 / p99 の目標 / 実測 / 翻訳したしきい値 / 根拠」の表を作る。件数は `crit = max(許容エラー件数, 5)`、`warn = max(crit ÷ 2, 2)`。p99 は目標を crit、80% を warn
4. AskUserQuestion で **1 問だけ**: 「この目標で監視を作ってよいか」。選択肢は「この通り」「全体を厳しく」「全体を緩く」。個別の修正は「その他」で受ける
5. 承認後、フェーズ 5 の `--svc` に翻訳する。`worker` の RED ルールは作らない（`--services` から外す）

### フェーズ 5: 監視ルール

```bash
${CLAUDE_SKILL_DIR}/scripts/create-monitors.sh \
  --svc "web|err=2/5|p99=800/1000|slo=可用性 99.9% / p99 1000ms|note=入口。実測 3000 件/5分 × 0.1% = 3 件 → 下限 5" \
  --svc "api|err=2/5|p99=2000/2500|slo=可用性 99.95% / p99 2500ms|note=呼び出し元 web のタイムアウト 5s の半分" \
  [--public-url "$PUBLIC_URL"] [--extra "stale jobs|max(app.jobs.stale)||0"]
```

サービスごとに 5xx 件数（5 分あたり）と p99 の query 監視。名前は `[otel-onboarding:<project>] <service> ...`。`slo` と `note` は memo に入り、Mackerel の画面と report.sh で根拠が読める。
再実行は引数なしでよい（指定しない値は今の値を保つ）。しきい値だけ変えるなら `--svc "web|p99=1200/1500"` のように差分だけ渡す。`--error-*` / `--p99-*` は全サービス一括の一時上書き。
`--error-warn/--error-crit` は件数。Mackerel の PromQL はベクトル除算に対応しないため率では監視できない。

### フェーズ 6: ダッシュボード

```bash
${CLAUDE_SKILL_DIR}/scripts/create-dashboard.sh [--extra "サインアップ数 / 5m|sum(increase(app.signups.completed[5m]))|signups"]
```

サービスごとに Requests / 5xx errors / p99 の 3 グラフ。参考線と見出しの SLO 表はフェーズ 5 の監視ルールから読むので、監視ルールの後に実行する。更新時は RED の行だけ作り直し、以前 `--extra` で足したグラフは残る。出力された URL をユーザーに伝える。

### フェーズ 7: レポート

```bash
${CLAUDE_SKILL_DIR}/scripts/report.sh > MACKEREL_ONBOARDING.md
```

出力に **あなたが行った変更の要約**（変更ファイル一覧、各サービスの計装方法、追加した依存）を追記し、ユーザーに次を伝える:

- ダッシュボードと APM の URL、作った監視ルールと SLO の表
- しきい値の変え方（「checkout の p99 を 1500ms にして」と頼めばよいこと。`--svc` で差分だけ再実行）
- `${CLAUDE_SKILL_DIR}/scripts/teardown.sh` で Mackerel 上のリソースだけ消せること、コードは git で戻せること

## 失敗したとき

`references/troubleshooting.md` の表を見る。代表例:

- Node のスパン名が `GET` だけ → ESM のローダーフック漏れ
- Node のメトリクスだけ来ない → `OTEL_METRIC_EXPORT_TIMEOUT` 未設定
- Collector に何も届かない → Collector が 127.0.0.1 にバインド
- トレース API が 0 件 → `serviceNamespace` 未指定
- Go の APM ルートが実パスで分かれる → `http.route` 属性漏れ
- Collector が `telemetry type is not supported` で起動しない → MDOT でログを送ろうとしている
- ログの `traceId` が null → Go のミドルウェア順序 / Node の `console.log`
- 監視ルールが二重にある → v0.2 以前の接頭辞 `[otel-onboarding]` のルールが残っている。`${CLAUDE_SKILL_DIR}/scripts/teardown.sh --prefix "[otel-onboarding]" --monitors-only` で古い方だけ消す（`--monitors-only` を忘れるとダッシュボードも消える）

## 補足

- 対象が Kubernetes など compose 以外の場合、`${CLAUDE_SKILL_DIR}/scripts/discover.sh` と compose 向けの手順は使えない。references の計装手順と Collector 設定、Mackerel API のスクリプト（verify / monitors / dashboard）は `--services` と `--exclude-routes` を明示すれば流用できる。
- このスキルは `references/` に検証済みのバージョン（SDK・Collector）を記録している。大きくバージョンが進んだ場合は「よくある詰まり」が変わっている可能性があるので、Collector の debug 出力で実際のメトリクス名を確認してから進める。
