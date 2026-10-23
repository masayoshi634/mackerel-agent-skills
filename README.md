# mackerel-agent-skills

[日本語](#日本語) | [English](#english)

## 日本語

[Mackerel](https://mackerel.io/) と OpenTelemetry のための [Agent Skills](https://agentskills.io/)。Claude Code のプラグインとして配布しています（Codex などでもスキルとして読み込めます）。

| スキル | バージョン | できること |
|---|---|---|
| [`mackerel-otel-onboarding`](skills/mackerel-otel-onboarding/SKILL.md) | 0.4.0 | docker compose で動くアプリに OpenTelemetry を計装し、Collector、SLO から導いたしきい値の監視ルール、RED ダッシュボードを Mackerel に作る。必要なのは `MACKEREL_APIKEY`（Write 権限）だけ |
| [`mackerel-incident-triage`](skills/mackerel-incident-triage/SKILL.md) | 0.2.1 | Mackerel のアラートを起点に、メトリクス・トレース・ログ・APM とアプリのコードを突き合わせて原因箇所（`file:line`）を特定し、7 項目の報告と GitHub Issue にする。Mackerel には書き込まない（Read 権限で可） |

### インストール（Claude Code）

```bash
claude plugin marketplace add masayoshi634/mackerel-agent-skills
claude plugin install mackerel-otel-onboarding@mackerel-agent-skills
claude plugin install mackerel-incident-triage@mackerel-agent-skills
```

- スキルは description で自動的に起動します（「Mackerel で監視を始めたい」「このアラートを調査して」など）。明示的に呼ぶときは `/mackerel-otel-onboarding:mackerel-otel-onboarding`
- 更新: `claude plugin update mackerel-otel-onboarding@mackerel-agent-skills`
- private リポジトリの間は git の認証（SSH か `gh auth setup-git`）が必要です

### Codex などプラグインの仕組みが無いエージェント

リポジトリを clone し、スキルのディレクトリをエージェントのスキル置き場に symlink します。

```bash
git clone git@github.com:masayoshi634/mackerel-agent-skills.git
ln -s "$PWD/mackerel-agent-skills/skills/mackerel-otel-onboarding" ~/.agents/skills/
ln -s "$PWD/mackerel-agent-skills/skills/mackerel-incident-triage" ~/.agents/skills/
```

このリポジトリ自体を開いた場合は `.agents/skills/` から読み込まれます。

### 必要なもの

- bash、curl、jq（両スキル）。onboarding は docker compose v2 も必要
- `MACKEREL_APIKEY`（環境変数か `.env`。ファイルにキーを書き込むことはしません）
- triage で Issue を作る場合は認証済みの `gh`（無ければ `INCIDENT_<日付>.md` に書き出します）

### デモ

EC サイトのデモアプリに onboarding を適用し、障害を起こして triage で調査する一連の流れは [mackerel-otel-demo](https://github.com/masayoshi634/mackerel-otel-demo) にあります。

### 開発

```bash
claude --plugin-dir ./plugins/mackerel-otel-onboarding --plugin-dir ./plugins/mackerel-incident-triage   # 作業ツリーのスキルで試す
make skill-check   # frontmatter / 参照切れ / shellcheck / gofmt / plugin.json / marketplace.json / claude plugin validate
```

- スキル本体は `skills/<name>/`。`plugins/<name>/skills/<name>` はそこへの symlink（インストール時に実体がコピーされます）
- バージョンを上げるときは `plugins/<name>/.claude-plugin/plugin.json` の `version` と SKILL.md の `metadata.version` を揃えます（`make skill-check` が検査）
- SKILL.md のスクリプトは `${CLAUDE_SKILL_DIR}/scripts/...` で参照します（プラグインとして入れたときにパスが壊れないように）
- PR では GitHub Actions が `make skill-check` を実行します

### ライセンス

MIT

---

## English

[Agent Skills](https://agentskills.io/) for [Mackerel](https://mackerel.io/) and OpenTelemetry, distributed as Claude Code plugins (they also load as plain skills in Codex and other agents). The skill bodies are written in Japanese.

| Skill | Version | What it does |
|---|---|---|
| [`mackerel-otel-onboarding`](skills/mackerel-otel-onboarding/SKILL.md) | 0.4.0 | Instruments a docker compose application with OpenTelemetry and sets up a Collector, SLO-derived alert monitors and a RED dashboard in Mackerel, with nothing but a `MACKEREL_APIKEY` (write permission) |
| [`mackerel-incident-triage`](skills/mackerel-incident-triage/SKILL.md) | 0.2.1 | Starts from a Mackerel alert, correlates metrics, traces, logs, APM stats and the application code to pinpoint the causing lines (`file:line`), and reports in seven sections, optionally as a GitHub Issue. Read-only on Mackerel |

### Install (Claude Code)

```bash
claude plugin marketplace add masayoshi634/mackerel-agent-skills
claude plugin install mackerel-otel-onboarding@mackerel-agent-skills
claude plugin install mackerel-incident-triage@mackerel-agent-skills
```

- Skills trigger automatically from their descriptions ("start monitoring with Mackerel", "investigate this alert"). Invoke explicitly with `/mackerel-otel-onboarding:mackerel-otel-onboarding`
- Update: `claude plugin update mackerel-otel-onboarding@mackerel-agent-skills`
- While the repository is private, git authentication (SSH or `gh auth setup-git`) is required

### Codex and other agents without plugins

Clone the repository and symlink the skill directories into your agent's skills directory.

```bash
git clone git@github.com:masayoshi634/mackerel-agent-skills.git
ln -s "$PWD/mackerel-agent-skills/skills/mackerel-otel-onboarding" ~/.agents/skills/
ln -s "$PWD/mackerel-agent-skills/skills/mackerel-incident-triage" ~/.agents/skills/
```

When this repository itself is opened, the skills load from `.agents/skills/`.

### Requirements

- bash, curl and jq (both skills). onboarding also needs docker compose v2
- `MACKEREL_APIKEY` in the environment or `.env` (the skills never write the key to files)
- An authenticated `gh` to file Issues from triage (otherwise it writes `INCIDENT_<date>.md`)

### Demo

[mackerel-otel-demo](https://github.com/masayoshi634/mackerel-otel-demo) shows the full flow: onboarding an uninstrumented e-commerce demo app, injecting a failure, and investigating it with triage.

### Development

```bash
claude --plugin-dir ./plugins/mackerel-otel-onboarding --plugin-dir ./plugins/mackerel-incident-triage   # try the working-tree skills
make skill-check   # frontmatter / broken references / shellcheck / gofmt / plugin.json / marketplace.json / claude plugin validate
```

- Skill sources live in `skills/<name>/`. `plugins/<name>/skills/<name>` is a symlink to them (copied as real files on install)
- When bumping a version, keep `version` in `plugins/<name>/.claude-plugin/plugin.json` and `metadata.version` in SKILL.md in sync (`make skill-check` enforces it)
- SKILL.md references scripts as `${CLAUDE_SKILL_DIR}/scripts/...` so paths keep working when installed as a plugin
- GitHub Actions runs `make skill-check` on pull requests

### License

MIT
