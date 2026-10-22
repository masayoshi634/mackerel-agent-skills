---
name: mackerel-incident-triage
description: Investigate a Mackerel alert end to end using only the Mackerel API (read-only, no MCP server) and the application's source code. Starts from an open alert, classifies the monitor type and what can be traced, checks metrics (alert value, host/service metrics, APM route stats before/after), joins representative traces with same-traceId logs to detect failure patterns (caller timed out while the callee succeeded, deepest 5xx, DB errors, inconsistency gauges), then inspects the code to pinpoint the causing lines (file:line), and reports symptoms / cause (direct and structural) / evidence / impact / mitigation / permanent fix / verification, optionally filing a GitHub Issue after approval. Use when the user asks to investigate / triage / find the root cause of an alert or incident in Mackerel, or says アラートの調査 / 障害対応 / 原因を調べて / トレースとログを突き合わせて / 原因箇所を特定して / Issue に報告して.
license: MIT
compatibility: Requires bash, curl, jq and network access to api.mackerelio.com. gh (authenticated) is optional and only used to file the Issue. For traces and logs, the application must send them to Mackerel via OpenTelemetry (e.g. with the mackerel-otel-onboarding skill); host/service metric monitors can be investigated without it. A MACKEREL_APIKEY with Read permission is enough.
metadata:
  author: masayoshi634
  version: "0.2.0"
---

# Mackerel アラート調査（triage）

Mackerel のアラートを起点に、**アラート → メトリクス → トレース・ログ・APM → コード** の順で証拠を集め、
「何が起きているか」「原因（直接・構造的）」「原因箇所（`file:line`）」「影響」「止血」「恒久対策」「確認方法」を根拠付きで報告し、承認を得て Issue に残す。
Mackerel API だけを使い（読み取りのみ）、コードは読むだけで変えない。OpenTelemetry で Mackerel に送っているアプリならそのまま使える。
ホスト・サービスメトリックの監視でも、トレースとログが無い範囲で調べられる。

## 不変条件（必ず守る）

1. **Mackerel に書き込まない。** アラートを閉じる、監視ルールを変える、といった操作は人が行う。スクリプトは GET と検索の POST だけ。
2. **API キーを出力しない。** `MACKEREL_APIKEY` は環境変数（または `.env`）から読むだけ。Read 権限で足りる。
3. **根拠の無い断定をしない。** 仮説には必ず「どのログ（本文・件数）」「どのトレース（traceId・span）」「どのコード行」を添える。推測は推測と書く。
4. **アプリのコードを変えない。** コードは読んで `file:line` を示すだけ。恒久対策は提案に留める（実装は別の作業として依頼を受ける）。
5. **GitHub Issue は承認を得たときだけ作る。** 報告の後に 1 問で確認し、承認が無ければ作らない。
6. 時間窓は **最大 30 分**（トレース・ログ・APM の API の制限）。長い障害は窓をずらして複数回見る。API はレート制限が厳しいので、スクリプト以外で連続して叩かない。

## 入力

| 変数 | 必須 | 既定 | 用途 |
|---|---|---|---|
| `MACKEREL_APIKEY` | 必須 | - | Read 権限で可 |
| `OTEL_SERVICE_NAMESPACE` | 任意 | 空 | `service.namespace`。計装時に付けていれば **必ず同じ値** を渡す（無いと検索が 0 件になる） |

ユーザーからは「アラートの URL か ID」「監視ルール名」「サービス名」のどれかを受け取る。何も無ければフェーズ 1 の一覧から選んでもらう。
コードの場所（`--repo`）は、カレントディレクトリがそのアプリのリポジトリでなければ聞く。

## 進め方

各フェーズの先頭で何をするかを 1〜2 行で伝える。スクリプトは `${CLAUDE_SKILL_DIR}`（このスキルのディレクトリ。プラグインとして入れた場合も Claude Code が展開する）基準で実行する。references 内の `scripts/...` も同じく `${CLAUDE_SKILL_DIR}/scripts/...` と読み替える。

### フェーズ 0: 事前確認

```bash
${CLAUDE_SKILL_DIR}/scripts/preflight.sh
```

curl / jq、API キー、組織名、開いているアラート数、`gh` の認証（任意。無ければ Issue はファイルにフォールバック）を確認する。

### フェーズ 1: アラートの把握

```bash
${CLAUDE_SKILL_DIR}/scripts/alerts.sh [--prefix "[otel-onboarding:<project>]"] [--with-closed]
```

開いているアラートに監視ルール名・**種別**・しきい値・対象サービス・メトリクス名と、種別ごとに辿れる範囲（`scope`）を付けて表と JSON で出す。
複数あるときは **CRITICAL → 古い順** に並ぶ。同じ時刻に複数が鳴っていれば、呼び出し関係の下流（末端）から見る。
ユーザーがアラートの URL を貼った場合は末尾の ID を使う。

| `scope` | 調べられるもの | このあとのフェーズ |
|---|---|---|
| `apm-traces-logs`（query 監視） | APM 統計、トレース、ログ | 2 → 3 → 4 |
| `host-metrics` / `service-metrics` | メトリクスの推移（`metrics.sh`） | 2 → 4（コードで設定・直近の変更を見る）。トレース・ログは無い |
| `external-url` | 応答時間とステータス（アラートの値） | URL が計装済みサービスの入口なら `triage.sh --service` でそのサービスを見る |
| `check-host` / `expression` | アラートの値、ホスト側の状態 | 2 のみ。限界を報告に書く |

### フェーズ 2: メトリクスの確認

アラートの値だけで判断せず、**前後の変化** を見る。

- アラートの値と発生時刻（`alerts.sh` の `value` / `opened_at`）。しきい値に対してどれだけ超えているか
- 同じサービスの他の監視ルールの状態（`alerts.sh --with-closed` を見て、同時刻に鳴ったものと鳴っていないものを分ける。p99 だけか、5xx もか、業務のゲージもか）
- ホスト・サービスメトリック監視なら推移と前後比較: `${CLAUDE_SKILL_DIR}/scripts/metrics.sh --host <hostId> --name <metric> --at <opened_epoch>`（`--service <name>` も同様）
- query 監視（OpenTelemetry のラベル付きメトリクス）は値を取る API が無い。APM のルート別統計（フェーズ 3 の `triage.sh` が出す件数・エラー率・p95）を発生前後の窓で比べる: `--at` を発生時刻の 20 分前と発生時刻で 2 回実行する
- グラフで見たいものはダッシュボード / メトリックエクスプローラーの URL を示す

### フェーズ 3: トレースとログの突き合わせ（自動）

```bash
${CLAUDE_SKILL_DIR}/scripts/triage.sh --alert <ALERT_ID> [--namespace "$OTEL_SERVICE_NAMESPACE"] [--window 30] [--traces 3] [--out ./triage-$(date +%Y%m%d-%H%M)]
# アラートが無い / 過去の障害: --monitor "名前" や --service checkout と --at <epoch> で窓を指定
```

やること: アラート → 監視ルール → 起点サービス。対象サービス（監視ルールの PromQL に出る全 `service.name`）ごとに APM のルート別統計と WARN/ERROR ログの集計。
起点サービスのログに付いた traceId と「遅い順」の検索から代表トレースを数件選び、`trace.sh` で全サービスの span・event・同じ traceId のログを突き合わせて **検出パターン** と **仮説（直接原因・構造的な原因付き）** を出す。
Markdown のレポートが出る（`--out` で JSON も保存）。`--out` はリポジトリの外か、`.gitignore` 済みの場所にする。

必要なところだけ個別に深掘りする:

```bash
${CLAUDE_SKILL_DIR}/scripts/trace.sh <traceId> --logs            # 1 トレースのウォーターフォール + 同じ traceId の全サービスのログ
${CLAUDE_SKILL_DIR}/scripts/logs.sh --service payment --grep "ord_xxx"                      # 業務キーで横断検索（本文と属性）
${CLAUDE_SKILL_DIR}/scripts/logs.sh --service checkout --severities WARN,ERROR --window 30 --raw
```

`references/patterns.md` の表で、検出パターンごとに「確定のための確認」と「コードで探すもの」を見る。

### フェーズ 4: コードの確認

`references/code-inspection.md` に従い、証拠をコードの行に落とす。

1. コードの場所を決める（`--repo`、カレントの git リポジトリ、無ければ聞く。手元に無ければ「特定できない」と報告に書く）
2. サービス名 → ディレクトリの対応表を作る（compose の `build.context`、同名ディレクトリ、`OTEL_SERVICE_NAME` の設定箇所）
3. 証拠（ログ本文、`failure_reason`、ルート、タイムアウト値）を **そのまま grep** し、パターン別の観点で行を特定する
4. 「原因箇所」表（`file:line` / 何をしている / なぜ原因か）を 2〜5 行にまとめる
5. 止血の手段をリポジトリから探す（直近の変更 `git log --since`、設定値、`admin` / `reconcile` / `repair` のルートや Makefile のターゲット）。見つからなければ「見つからない」と書く

### フェーズ 5: 報告

`references/report-format.md` の 7 項目で、短く。**Mackerel の画面（アラート、監視ルール、APM、トレース、ログ、ダッシュボード）とコードの行はすべてリンクにする**（`triage.sh` の `urls` / `traces[].url` / `findings[].url` と、GitHub のパーマリンク。作り方は report-format.md）:

1. **何が起きているか**（症状の広がり: どのサービスのどのルートが、どれくらい）
2. **原因**（直接原因と構造的な原因を分ける。原因箇所の表を添え、`file:line` はパーマリンク）
3. **起点と根拠**（代表トレースのリンク、決め手になった span のリンクとログ本文、ログ検索のリンク）
4. **影響**（失敗した処理の件数と率、不整合があればその件数と業務キーの例）
5. **止血**（リポジトリから見つけた手段を順に。設定の戻し、復旧コマンド。無ければ手動の手当て）
6. **恒久対策**（構造的な原因ごとに、原因箇所の `file:line` を添えた提案）
7. **確認方法**（止血後に何が OK に戻るか。アラート名とダッシュボードのグラフ）

断定できないことは「〜の可能性。確認には〜」と書く。アラートを閉じるのは人に委ねる。

### フェーズ 6: Issue 作成 → 承認

報告の直後に AskUserQuestion で **1 問だけ**: 「この報告を Issue にしますか」。選択肢は「新規に作る」「既存の Issue #N に追記する」「作らない」。
承認されたら `references/report-format.md` の形式で本文を作り、`gh issue create`（または `gh issue comment`）で登録して URL を伝える。
`gh` が無い、未認証、またはリモートが GitHub でなければ、同じ本文を `INCIDENT_<日付>.md` に書く（ファイルを作るので承認を得る）。

## 失敗したとき

| 症状 | 対処 |
|---|---|
| ログ・トレースが 0 件 | `--namespace` が計装時の `service.namespace` と一致しているか。窓が 30 分以内か。送信から見えるまで 1〜2 分の遅れ |
| `HTTP 429 Rate limit exceeded` | スクリプトは待って再試行する。並列に別のスクリプトを走らせない |
| 調査対象のサービスが分からない | 監視ルールの PromQL に `service.name` が無い（カスタムメトリクスの監視）。`--services a,b,c` で渡す |
| 代表トレースに error が無い | 遅延やトラフィック量の問題。`--traces` を増やす、`--service` を下流に変える |
| アラートが直近 100 件に無い | `--monitor "名前" --at <発生時刻の epoch>` で窓を指定する |
| ホスト・サービスメトリックが 404 | ホスト ID / サービス名とメトリック名を確認する（`alerts.sh` の `host_id` と `metric`） |
| コードが見つからない | `--repo` で場所を聞く。無ければ原因箇所の表を省き、恒久対策は「コードを特定できないため一般論」と明記する |
| `gh` で Issue が作れない | `gh auth status` を確認。作れなければ `INCIDENT_<日付>.md` にフォールバック |

## 参照

- `references/mackerel-api.md`: 使う API と応答の形、監視ルールの種別ごとに辿れる範囲、制限
- `references/patterns.md`: 検出パターン → 直接原因・構造的な原因 → 確認手順 → コードで探すもの → 止血・恒久対策
- `references/code-inspection.md`: コードの場所の決め方、証拠から行を探す手順、原因箇所の表
- `references/report-format.md`: 報告の 7 項目、Issue と `INCIDENT_<日付>.md` の形式
