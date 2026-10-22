# inventory（`scripts/discover.sh` の出力）

架空の構成（Node の `web`、Go の `api`、Python の `worker`）での例:

```json
{
  "project": "my-app",
  "existing_collector": null,
  "app_services": ["web", "api", "worker"],
  "exclude_routes": ["/healthz"],         // app サービスの healthcheck_path の集合。無ければ ["/healthz"]。監視・ダッシュボードが自動で使う
  "languages": ["go", "node", "python"],
  "services": [
    {
      "name": "web",
      "kind": "app",                       // build があれば app、image だけなら infra
      "image": null,
      "build_context": "./services/web",
      "ports": ["3000->3000"],
      "depends_on": ["api"],
      "upstream_env": {"API_URL": "http://api:8080"},   // URL/HOST/ENDPOINT を含む env
      "healthcheck": ["CMD", "wget", "-qO-", "http://localhost:3000/healthz"],
      "healthcheck_path": "/healthz",             // healthcheck の URL から切り出したパス（無ければ null）
      "profiles": [],
      "otel_env_present": false,
      "language": "node",                  // node | python | go | ruby | java | php | dotnet | unknown
      "framework": ["express"],
      "manifest": "package.json",
      "module": "module",                  // node: commonjs|module、go: モジュールパス
      "dockerfile_cmd": "[\"node\", \"src/server.ts\"]",
      "dockerfile_entrypoint": "",
      "already_instrumented": false,       // 依存に opentelemetry があるか
      "notes": ["ESM: ローダーフック（--experimental-loader）が必要", "TypeScript を直接実行している"]
    }
  ]
}
```

## LLM が計画を立てるときの確認観点

1. `app_services` が計装対象。`infra`（postgres / redis / nginx 等）は計装しない
2. `profiles` が付いているサービス（負荷試験用のクライアントなど）は既定で対象外にしてよいが、ユーザーに確認する
3. `already_instrumented: true` のサービスは「既存の設定を Collector 向けに揃える」だけにする
4. `existing_collector` があれば新規に追加せず、その設定に Mackerel の exporter を足す
5. `language: unknown` は `references/instrument-other.md` を読み、ユーザーに言語を確認する
6. `upstream_env` と `depends_on` から呼び出し関係を把握し、トレースが貫通するか（クライアント計装の有無）を考える
7. `exclude_routes` はメトリクスと監視から自動で除外される。`/healthz` 以外が含まれるなら Go の `OTEL_HTTP_EXCLUDE_PATHS` と Collector の `filter/logs` も合わせる
8. `ports`（公開）、`depends_on`、`upstream_env`（他サービスを指すか外部か）は、フェーズ 4.5 の役割判定（`references/slo.md`）にも使う
