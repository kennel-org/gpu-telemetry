# gpu-telemetry

NVIDIA GPU を搭載した Linux ホスト向けの GPU テレメトリ収集ツールです。
PostgreSQL に保存するテレメトリ収集と、`gpu-burn` を状態タグ付きで実行する補助スクリプトを提供します。

主用途は、Minisforum X1 AI + DEG1 eGPU + Tesla P40 × 2 の構成で `gpu-burn` 等の負荷時に GPU 温度を継続監視することです。マルチ GPU 構成にも対応しており、同一ホストに複数 GPU がある場合でも GPU ごとに正しくテレメトリを収集します。

## このリポジトリが提供するもの

- `nvidia-smi` ベースのテレメトリ収集
- PostgreSQL スキーマ（`sql/001_init.sql`）
- DB障害時にローカルファイルへスプール（`spool/`）
- `gpu-burn` 実行前後で状態タグを付与するラッパ（`bin/run_gpuburn.sh`）

> 注意: このリポジトリには `gpu-burn` のソースは含みません。`~/projects/gpu-burn` に `gpu_burn` バイナリがビルド済みである前提です。

## 保存している内容

`telemetry.gpu_telemetry` に、1 サンプルあたり GPU 1 台につき 1 行:

| カラム | 内容 |
|---|---|
| `ts`, `host`, `gpu_uuid` | 主キー |
| `pci_bus_id`, `gpu_name` | GPU の識別情報 |
| `temp_c` | 温度（°C） |
| `gpu_util_pct`, `mem_util_pct` | 使用率（%） |
| `mem_used_mib`, `mem_total_mib` | VRAM |
| `power_w`, `fan_pct`, `sm_clock_mhz`, `perf_state` | 消費電力 / ファン / クロック / P-state |
| `processes` | jsonb: GPU 上で何が動いているか — `[{"pid","type","name","used_mib"}, ...]`（`type` は C = compute、G = graphics） |
| `status_tag`, `status_memo` | `status.json` で付ける運用タグ |
| `raw_json` | `nvidia-smi -q -x` のスナップショット全文 |

## 運用ドキュメント

- 運用: `docs/operations.ja.md`

## ディレクトリ構成（概要）

- `bin/collect_once.py`（1回収集してDBへINSERT。失敗時はスプール）
- `bin/collect_loop.sh`（収集ループ）
- `bin/flush_spool.py`（スプールflush）
- `bin/set_status.sh`（`status.json` 更新）
- `bin/run_gpuburn.sh`（`gpu-burn` 実行 + 状態タグ）
- `bin/init_db.sh`（スキーマ適用）
- `bin/host_healthcheck.sh`（ホストの簡易ヘルスチェック）
- `sql/001_init.sql`, `sql/002_add_metric_columns.sql`（スキーマ。`init_db.sh` が順に適用）
- `bin/nvsmi_parse.py`（`nvidia-smi -q -x` をメトリクスカラムへパース）
- `bin/backfill_metrics.py`（カラム追加前に収集した行のバックフィル）

## ライセンス

MIT（`LICENSE` を参照）。
