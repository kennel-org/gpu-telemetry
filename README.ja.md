# gpu-telemetry

NVIDIA GPU を搭載した Linux ホスト向けの GPU テレメトリ収集ツールです。
PostgreSQL に保存するテレメトリ収集と、`gpu-burn` を状態タグ付きで実行する補助スクリプトを提供します。

主用途は、Minisforum X1 AI + DEG1 eGPU + Tesla P40 の構成で `gpu-burn` 等の負荷時に GPU 温度を継続監視することです。

## このリポジトリが提供するもの

- `nvidia-smi` ベースのテレメトリ収集
- PostgreSQL スキーマ（`sql/001_init.sql`）
- DB障害時にローカルファイルへスプール（`spool/`）
- `gpu-burn` 実行前後で状態タグを付与するラッパ（`bin/run_gpuburn.sh`）

> 注意: このリポジトリには `gpu-burn` のソースは含みません。`~/projects/gpu-burn` に `gpu_burn` バイナリがビルド済みである前提です。

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
- `sql/001_init.sql`（スキーマ）

## ライセンス

MIT（`LICENSE` を参照）。
