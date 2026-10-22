# 使う Mackerel API と注意点

ベース URL `https://api.mackerelio.com`、認証ヘッダ `X-Api-Key`。`scripts/lib.sh` の `mkr_api METHOD PATH [BODY]` を使う。

| 用途 | API | 使う場所 |
|---|---|---|
| キー検証・組織名 | `GET /api/v0/org` | preflight / report |
| トレース検索 | `POST /api/v0/traces` `{serviceName, serviceNamespace, from, to, perPage, order}` | verify-ingest |
| トレース詳細 | `GET /api/v0/traces/{traceId}` | 調査用 |
| ルート別統計 | `GET /api/v0/apm/http-server-stats?serviceName&serviceNamespace&from&to&orderColumn` | verify-ingest / report |
| ログ検索 | `POST /api/v0/logs` `{serviceName, serviceNamespace, from, to, perPage}` → `results[].{timestamp, severity, body, traceId, spanId, attributes}`, `cursor` | verify-ingest --logs |
| DB 統計 | `GET /api/v0/apm/db-query-stats?serviceName&serviceNamespace&from&to` | report（任意） |
| ダッシュボード | `GET/POST /api/v0/dashboards`, `PUT/DELETE /api/v0/dashboards/{id}` | create-dashboard / teardown |
| 監視ルール | `GET/POST /api/v0/monitors`, `PUT/DELETE /api/v0/monitors/{id}` | create-monitors / teardown |

## 落とし穴

- **DELETE にも `Content-Type: application/json` が必要**（ないと 400 `Illegal Content-Type`）。`mkr_api` は常に付ける。

- **PromQL のクエリ API は公開されていない。** メトリクスが届いたかを API で直接確認する手段はない。
  到達確認はトレース API と APM 統計 API で行い、メトリクスはダッシュボードを作って画面で確認する（反映まで 1〜2 分）。
- **`service.namespace` を付けたら API にも `serviceNamespace` を渡す。** 渡さないと既定の空文字で検索され 0 件になる。
  `OTEL_RESOURCE_ATTRIBUTES` に `service.namespace=...` を入れた場合は verify-ingest / report に `--namespace` を渡す（discover から自動取得も試みる）。
- **トレース検索 API と APM 統計 API の `from`〜`to` は最大 30 分**（超えると 400）。
- **レート制限が厳しい。** 数秒間隔で連続して叩くと `HTTP 429`（以前は `HTTP 500`）で `{"error":{"message":"Rate limit exceeded"}}` が返る。`mkr_api` は 15 秒 × 試行回数待って再試行する。ポーリングは 10〜15 秒間隔にし、サービスごとの呼び出しの間にも 1 秒空ける。
- トレースは送信から API で見えるまで 1〜2 分かかることがある。verify-ingest は既定 180 秒待つ。
- ヒストグラムは Mackerel 側で `.count` `.sum` `.min` `.max` `.p90` `.p95` `.p99` の代表値に変換される。Counter（Sum）と Gauge は元の名前のまま。
  `histogram_quantile()` は使えない。`one-to-many`（`group_left`）も未対応。
- **ベクトル同士の除算 `/` は動かない**（空になる）。`+` `-` `* 定数` `scalar()` 比較演算は動く。率が必要な指標は件数に置き換える。
- ダッシュボードのグラフの `referenceLines` は **1 本まで**（2 本入れると 400）。
- **監視ルールの PUT は監視対象（`query` / `url`）を変更できない**（400 `cannot change target`）。しきい値・名前・メモの変更は PUT、対象の変更は DELETE → POST（アラート履歴は新しいルールに引き継がれない）。
- 監視ルールの `query` タイプは `operator` が `>` か `<`、`evaluateBackwardMinutes` は 0〜10。
- ダッシュボードの `urlPath` は組織内で一意。重複すると 409。スキルは `otel-onboarding-<project>` を使い、既存があれば PUT で更新する。
- Write 権限のないキーだと作成系が 403。読み取り専用キーでは preflight は通ってしまうので、403 が出たらキー権限を疑う。
