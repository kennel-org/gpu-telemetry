# 運用（X1 AI + DEG1 eGPU + Tesla P40 温度監視ランブック）

このドキュメントは、Minisforum X1 AI に DEG1 eGPU ドック経由で Tesla P40 を接続した環境で、GPU 温度を中心にテレメトリを収集・確認するためのゼロベース手順です。

## ゴール

- `nvidia-smi` で GPU が見える
- テレメトリが PostgreSQL に継続投入される（DB停止時は `spool/` に退避し、復旧後 flush される）
- `gpu-burn` で負荷を掛け、温度上昇が DB に記録される

注記:

- 本ドキュメントは、ベンチ中も含めてテレメトリ収集が常時動作している（例: `systemd --user` の `gpu-telemetry.service` と `gpu-telemetry-flush.timer`）前提です。ベンチ用スクリプトは主に `status.json`（`status_tag`/`status_memo`）を更新し、後から DB/プロットを絞り込めるようにします。

## ハード構成（BOM）

- **Host**: Minisforum X1 AI
- **eGPU Dock**: DEG1 eGPU
- **GPU**: NVIDIA Tesla P40 × 2（`01:00.0` / `07:00.0`）
- **電源**: 玄人志向 600W ATX電源

参考価格（2025年12月時点）:

- Nvidia Tesla P40 24GB(中古) ¥30,345-
- Minisforum X1 AI 32GB/1TB SSD ¥107,993-
- Minisforum DEG1 eGPU Dock ¥11,381-
- 600W ATX電源 ¥4,598-
- 秋月 DCファン YDH9225C12F（92×92×25mm, 12V）¥450-
  - https://akizukidenshi.com/catalog/g/g114359/
- PWM ミニ DC モータ スピードコントローラー（DC 5V-35V / 5A）
  - https://amzn.asia/d/00DUdF1a

## 前提条件

- NVIDIA ドライバ導入済みで `nvidia-smi` が動作する
- PostgreSQL に接続できる（同一ホストでも別ホストでも可）
- `psql` コマンド（`bin/init_db.sh` で使用）
- Python 3
- `uv`（Python 環境/依存の管理）

任意（あると便利）:

- `tmux`（長時間実行推奨）
- `lm-sensors`, `nvme-cli`, `smartmontools`（診断ログ収集で使用）

## 0. 事前確認（GPU認識）

`nvidia-smi` で P40 が認識できる状態になるまでの手順は、以下を参照してください。

- `docs/p40-nvidia-smi.ubuntu22.ja.md`

```bash
nvidia-smi
nvidia-smi -L
nvidia-smi --query-gpu=name,uuid,pci.bus_id,temperature.gpu,power.draw --format=csv
```

ここで P40 が出ない場合は、先に `bin/host_healthcheck.sh` を実行してログを取ってから切り分けしてください。

## 1. セットアップ（リポジトリ側）

### 1.1 `.env` を作成

`.env.example` を `.env` にコピーして、PostgreSQL 接続情報を編集します（`.env` はコミットしません）。

```bash
cp .env.example .env
```

必須:

- `PGHOST`
- `PGPORT`
- `PGDATABASE`
- `PGUSER`
- `PGPASSWORD`

任意:

- `PGSSLMODE`（デフォルト: `prefer`）
- `SAMPLE_INTERVAL_SEC`（収集間隔秒。systemd / ループ実行に合わせる）

### 1.2 uv で依存を導入

```bash
uv sync
```

### 1.3 DB スキーマを初期化

```bash
./bin/init_db.sh
```

`sql/` 配下の SQL を番号順に適用します。各ファイルは `IF NOT EXISTS` で冪等なので、
新規構築でも既存 DB へのマイグレーションでも同じコマンドで済みます。

## 2. まずは単発収集で疎通確認

```bash
uv run ./bin/collect_once.py
```

- 成功時: PostgreSQL に INSERT
- 失敗時: `./spool/` に JSON 退避（`_spool_reason` に理由）

## 3. 常時収集（systemd ユーザーサービス）

推奨は systemd の user unit で常時稼働させる方法です。

### 3.1 インストール

```bash
mkdir -p ~/.config/systemd/user
cp ./systemd/gpu-telemetry.service ~/.config/systemd/user/
cp ./systemd/gpu-telemetry-flush.service ~/.config/systemd/user/
cp ./systemd/gpu-telemetry-flush.timer ~/.config/systemd/user/
systemctl --user daemon-reload
```

systemd の環境では `uv` が PATH に含まれないことがあります。その対策として、このリポジトリは `bin/uv.sh`（`uv` の実行パス解決ラッパー）を使用します。

### 3.2 有効化・起動

```bash
systemctl --user enable --now gpu-telemetry.service
systemctl --user enable --now gpu-telemetry-flush.timer
```

### 3.3 状態/ログ確認

```bash
systemctl --user status gpu-telemetry.service --no-pager -l
journalctl --user -u gpu-telemetry.service --no-pager -n 100

systemctl --user status gpu-telemetry-flush.timer --no-pager -l
journalctl --user -u gpu-telemetry-flush.service --no-pager -n 100
```

## 状態タグ（推奨運用: idle / prod / bench）

収集時に `status.json` を読み、`status_tag` / `status_memo` として DB に保存します。

推奨する運用タグ:

- `idle`
  - ふだんの平常運用。Open-WebUI/ollama を立ち上げていても「負荷は軽い」側。
  - 目的: 待機時の温度・消費電力・ファン挙動のベースライン取得
- `prod`
  - “実運用”扱い。推論（API/WEBUI）を普通に使っている状態。
  - 目的: 実際の利用時の温度・電力・スロットリング・VRAM推移を記録
- `bench`
  - ベンチ・焼き・負荷試験（gpu-burn / 長時間推論 / stress）。
  - 目的: 限界挙動（温度飽和、電力上限、クロック低下、エラー兆候）を取る

設定例:

```bash
cp ./status.json.example ./status.json

./bin/set_status.sh idle "baseline"
./bin/set_status.sh prod "inference (Open-WebUI/ollama)"
./bin/set_status.sh bench "gpu-burn"
```

`status.json` は運用状態なので、公開リポジトリには含めません。

## 4. 温度上昇テスト（gpu-burn）

### 4.1 前提

このリポジトリは `gpu-burn` のソースを含みません。以下が前提です。

- `~/projects/gpu-burn/gpu_burn`（ビルド済み）

### 4.2 実行（tmux 推奨）

```bash
./bin/run_gpuburn.sh \
  --pre-idle-sec 180 --pre-idle-memo "pre gpu-burn idle (baseline)" \
  --sec 900 --pre-tag bench --pre-memo "gpu-burn (max workload)" \
  --post-tag idle --post-memo "post gpu-burn idle" \
  --cooldown-sec 600 --cooldown-memo "cooldown idle (post gpu-burn)" \
  --final-tag prod --final-memo "prod (normal usage)" \
  --tmux
```

- `run_gpuburn.sh` は開始/終了で `status.json` を更新します
- ベンチ前アイドル（`--pre-idle-sec`）とクールダウン（`--cooldown-sec`）を含めて、温度変化の前後を取りやすくできます
- 最後に `prod`（通常使用）へ戻す運用にできます
- ログは `./logs/` に保存され、**終了時に自動で gzip 圧縮されます**（`gpu-burn-<STAMP>-<TAG>.log.gz`）

```bash
zless  logs/gpu-burn-20260830-150900-gpu0-fan75-current.log.gz
zgrep -c "errors: 0" logs/gpu-burn-*.log.gz
```

  gpu-burn は進捗行を `\r` で上書き出力し続けるため、**GPU が故障するとタイトループで
  同じ行を吐き続けます**。2026-08-30 に GPU 1 が `DIED` した実行では 899 MB・856万行に達し、
  そのうち1行が283,990回繰り返されていました。gzip で 0.34%（3.1 MB）まで落ちるため、
  内容を間引かず圧縮する方式にしています（`zcat` で完全に復元できます）。
  既に `.gz` がある場合は上書きせず警告のみ出します。

ベンチ実行中も、バックグラウンドでテレメトリ収集が動作している前提です。

### 4.3 LLM ベンチ（Ollama coding bench）

Ollama の複数モデルを対象に、推論を流しつつ `status_tag`/`status_memo` をマーキングします（後で DB/プロットを絞り込む用）。CSV 出力は任意です。

- スクリプト: `bin/run_ollama_coding_bench.sh`
- 出力先（任意）: デフォルトは `./bench_results/bench_<model>.csv`（`--no-csv` で無効化）
- モデル選定: `GET /api/tags` の一覧から `--coding-regex`（デフォルト: `(coder|starcoder|code)`）でフィルタし、baseline モデルも追加
- 実行順: サイズ昇順（小→大）で実行し、digest 重複は除外
- テレメトリのタグ付け:
  - pre/post/cooldown は `idle`（memo はオプションで変更可）
  - ベンチ本体は `bench` で memo が `ollama_<model>`

前提:

- Ollama が起動している（デフォルト: `http://127.0.0.1:11434`）
- 必要コマンド: `curl`, `jq`, `awk`, `sed`
- `status.json` が存在する（無い場合は `status.json.example` から作成）

実行（タイマーでテレメトリ収集中なら、CSVなしが推奨）:

```bash
./bin/run_ollama_coding_bench.sh --no-csv
```

オプション例:

```bash
./bin/run_ollama_coding_bench.sh \
  --no-csv \
  --repeat 5 \
  --num-predict 768 \
  --temperature 0 \
  --cooldown-sec 900 \
  --out-dir ./bench_results
```

実行せずに対象モデルだけ確認:

```bash
./bin/run_ollama_coding_bench.sh --dry-run
```

CSV のカラム（モデルごと。CSV出力を有効にした場合）:

- `model`
- `run`
- `prompt_id`
- `load_s`
- `prompt_tps`
- `gen_tps`
- `total_s`
- `prompt_tokens`
- `gen_tokens`

## 5. 結果確認

### 5.1 `nvidia-smi` での即時確認

```bash
nvidia-smi --query-gpu=timestamp,name,pci.bus_id,temperature.gpu,power.draw,utilization.gpu --format=csv
```

`gpu-burn` 実行中の連続モニタ（1秒間隔）:

```bash
nvidia-smi --query-gpu=timestamp,temperature.gpu,power.draw,power.limit,clocks.gr,pstate,utilization.gpu,fan.speed \
  --format=csv -l 1
```

### 5.2 DB での確認（例）

```bash
psql "host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} sslmode=${PGSSLMODE:-prefer}"
```

```sql
select
  ts,
  host,
  gpu_name,
  pci_bus_id,
  temp_c,
  status_tag,
  status_memo
from telemetry.gpu_telemetry
order by ts desc
limit 50;
```

```sql
select
  ts,
  host,
  gpu_name,
  pci_bus_id,
  temp_c,
  status_tag,
  status_memo
from telemetry.gpu_telemetry
where status_tag = 'bench'
order by ts desc
limit 200;
```

GPU が何を実行していたかは `processes`（jsonb）に入っています。

```sql
-- 最新サンプルで GPU 上にいるプロセス
select
  p->>'name'            as process,
  (p->>'pid')::int      as pid,
  p->>'type'            as type,      -- C = compute, G = graphics
  (p->>'used_mib')::int as vram_mib
from (
  select processes
  from telemetry.gpu_telemetry
  where host = 'x1ai'
  order by ts desc
  limit 1
) latest,
lateral jsonb_array_elements(latest.processes) p
order by vram_mib desc nulls last;
```

```sql
-- 期間内に VRAM を掴んでいたプロセスを消費量順に
select
  p->>'name'                  as process,
  max((p->>'used_mib')::int)  as peak_vram_mib,
  min(ts)                     as first_seen,
  max(ts)                     as last_seen
from telemetry.gpu_telemetry,
     lateral jsonb_array_elements(processes) p
where host = 'x1ai'
  and ts >= now() - interval '24 hours'
group by 1
order by 2 desc nulls last;
```

```sql
-- 稼働率・VRAM・電力の時系列（GPU 単位）
select ts, pci_bus_id, gpu_util_pct, mem_used_mib, power_w, perf_state
from telemetry.gpu_telemetry
where host = 'x1ai'
  and ts >= now() - interval '1 hour'
order by ts desc, pci_bus_id;
```

### 5.3 温度変化プロット（PNG出力）

DB から任意の範囲の温度推移を読み出して画像（PNG）に保存します。

例（直近 6 時間を `docs/images/gpu-temp.png` に保存）:

```bash
uv run ./bin/plot_temp.py --hours 6
```

例（期間指定。ISO8601）:

```bash
uv run ./bin/plot_temp.py \
  --start 2026-01-04T00:00:00+09:00 \
  --end   2026-01-04T06:00:00+09:00
```

例（`prod` だけ）:

```bash
uv run ./bin/plot_temp.py --hours 24 --status-tag prod
```

例（`prod` を除外して、ベンチ/非prod だけを見やすく）:

```bash
uv run ./bin/plot_temp.py --hours 24 --exclude-prod
```

例（`status_memo` でベンチを切り分けて別名保存。複数指定可）:

```bash
# fan 100%（ベースライン）
uv run ./bin/plot_temp.py --hours 24 --exclude-prod --include-memo "fan=100%" --out docs/images/gpu-temp-fan100.png

# fan 25%
uv run ./bin/plot_temp.py --hours 24 --exclude-prod --include-memo "fan=25%" --out docs/images/gpu-temp-fan25.png
```

### 5.4 Grafana ダッシュボード

テレメトリデータを Grafana で可視化できます。このリポジトリには、PostgreSQL データソース用のダッシュボードテンプレート `grafana/gpu-telemetry.json` が含まれています。

![GPU Telemetry Dashboard](images/grafana-gpu-telemetry.png)

#### パネル構成

| パネル | 種別 | 内容 |
|--------|------|------|
| Current Temperature | stat | 最新の GPU 温度（閾値: 60/75/85 で色変化） |
| Current Perf Mode | stat | 最新の `perf_state`（P0 / P2 / P8） |
| Max Temp | stat | 選択期間の最高温度 |
| Avg Temp | stat | 選択期間の平均温度 |
| GPU | stat | GPU 名 |
| Total Samples | stat | 選択期間のサンプル数 |
| Current GPU Utilization | stat | 最新の GPU 使用率 |
| Current VRAM Used | stat | 最新の VRAM 使用量 |
| Current Power Draw | stat | 最新の消費電力 |
| Processes on GPU | stat | 最新サンプルで GPU 上にいるプロセス数 |
| GPU Temperature | timeseries | 全GPU の温度時系列（GPU ごとに別系列。75/85 の閾値線付き） |
| GPU Utilization | timeseries | 全GPU の使用率時系列 |
| VRAM Used | timeseries | 全GPU の VRAM 使用量時系列 |
| Power Draw | timeseries | 全GPU の消費電力時系列 |
| Processes on GPU (latest sample) | table | 最新サンプルのプロセス一覧（PID / type / VRAM） |
| Top Processes in Range | table | 選択期間に VRAM を掴んだプロセスを消費量順に集計 |
| VRAM by Process | timeseries | プロセス別 VRAM 使用量の時系列 |
| Perf Mode Timeline | state-timeline | P0/P2/P8 の遷移タイムライン |
| Temperature by Perf Mode | timeseries | perf state 別の温度（色分け） |
| Temperature Distribution by Perf Mode | barchart | perf state 別 Min/Avg/Max |
| Samples by Perf Mode | piechart | perf state 別サンプル数（ドーナツチャート） |
| Recent Perf Mode Changes | table | perf state 変更履歴 |

#### 前提

- Grafana がインストール済み（動作確認: v11 以上）
- PostgreSQL データソースが作成済みで、`telemetry` データベースに接続できる

#### データソースの作成

Grafana の UI またはプロビジョニング YAML で PostgreSQL データソースを追加します。

プロビジョニング例（`/etc/grafana/provisioning/datasources/telemetry.yml`）:

```yaml
apiVersion: 1
datasources:
  - name: gpu-telemetry
    uid: gpu-telemetry-ds
    type: postgres
    access: proxy
    url: <DB_HOST>:<DB_PORT>
    user: <DB_USER>
    database: telemetry
    jsonData:
      sslmode: disable
      postgresVersion: 1700
      timescaledb: false
    secureJsonData:
      password: <DB_PASSWORD>
```

#### ダッシュボードのインポート

テンプレートには Grafana の datasource input 定義が含まれます。UI インポート時はデータソース選択プロンプトが表示されます。HTTP API で直接投入する場合は、従来どおり `${GRAFANA_DS_UID}` を作成したデータソースの UID に置換してからインポートします。

方法 A: Grafana HTTP API でインポート

```bash
# データソース UID を確認
DS_UID=$(curl -fSs -u <GRAFANA_USER>:<GRAFANA_PASSWORD> \
  http://<GRAFANA_HOST>:3000/api/datasources/name/gpu-telemetry \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['uid'])")

# テンプレートの UID を置換し、API ラッパーで包んでインポート
sed "s/\${GRAFANA_DS_UID}/${DS_UID}/g" grafana/gpu-telemetry.json \
  | python3 -c "
import sys, json
dash = json.load(sys.stdin)
payload = {'dashboard': dash, 'overwrite': True}
json.dump(payload, sys.stdout)
" \
  | curl -fSs -u <GRAFANA_USER>:<GRAFANA_PASSWORD> \
      -X POST http://<GRAFANA_HOST>:3000/api/dashboards/db \
      -H 'Content-Type: application/json' \
      -d @-

# インポート結果を確認
curl -fSs -u <GRAFANA_USER>:<GRAFANA_PASSWORD> \
  http://<GRAFANA_HOST>:3000/api/dashboards/uid/gpu-telemetry \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK:', d['meta']['url'])"

# 保存されたダッシュボードに未置換プレースホルダが残っていないことを確認
curl -fSs -u <GRAFANA_USER>:<GRAFANA_PASSWORD> \
  http://<GRAFANA_HOST>:3000/api/dashboards/uid/gpu-telemetry \
  | python3 -c 'import sys,json; s=json.dumps(json.load(sys.stdin)["dashboard"]); print("OK: datasource placeholder resolved" if "${GRAFANA_DS_UID}" not in s else "ERROR: unresolved datasource placeholder remains")'
```

方法 B: Grafana UI からインポート

1. Grafana にログイン
2. 左メニュー → Dashboards → New → Import
3. `grafana/gpu-telemetry.json` をアップロードまたは内容を貼り付け
4. `telemetry` datasource input が表示されたら、対象の PostgreSQL データソースに割り当てる
5. Import をクリック

UI で datasource input が表示されない場合や、API で直接投入する場合は、事前に `${GRAFANA_DS_UID}` を実際の UID に置換してください。

#### テンプレート変数

- **Host**: `telemetry.gpu_telemetry` テーブルの `host` カラムからドロップダウンで選択
- **GPU**: 選択した Host に紐づく GPU を PCI バス ID（例: `00000000:01:00.0`）で選択。stat パネルやフィルタ付きグラフに適用される。GPU Temperature グラフは選択に関わらず全 GPU を同時表示する

#### デフォルト設定

- 時間範囲: 過去 6 時間
- 自動リフレッシュ: 30 秒
- タイムゾーン: ブラウザ依存（`browser`）

## 6. スプール（DB停止時の退避）と flush

- `bin/collect_once.py` は DB INSERT 失敗時、`spool/` に JSON を退避します
- flush は以下で手動実行できます

```bash
uv run ./bin/flush_spool.py
```

## 7. 復旧手順（systemd unit を更新したとき）

unit ファイルを編集/差し替えたら、必ずリロードして再起動してください。

```bash
systemctl --user daemon-reload
systemctl --user restart gpu-telemetry.service
systemctl --user restart gpu-telemetry-flush.timer
```

## 8. トラブルシュート

### 8.1 GPU が見えない / `nvidia-smi` が失敗

- `bin/host_healthcheck.sh` を実行し、`dmesg` / `lsmod` / `/dev/nvidia*` を確認
- eGPU 側の電源投入順やケーブル/スロット接触、PCIe 周りのログを確認

```bash
./bin/host_healthcheck.sh
```

### 8.2 テレメトリが DB に入らない

- `systemctl --user status gpu-telemetry.service` と `journalctl` を確認
- `spool/` に溜まっていないか確認
- `.env` の接続情報（`PGHOST` 等）を確認

### 8.3 DB が重い / サイズ増加

- `bin/collect_once.py` は `nvidia-smi -q -x` の XML を、`raw_json`（jsonb）内の文字列として保存します（重い）
- サイズのほぼ全量は TOAST 側です。内訳の確認:

```sql
select pg_size_pretty(pg_relation_size('telemetry.gpu_telemetry'))  as heap,
       pg_size_pretty(pg_indexes_size('telemetry.gpu_telemetry'))   as idx,
       (select pg_size_pretty(pg_total_relation_size(reltoastrelid))
          from pg_class where oid = 'telemetry.gpu_telemetry'::regclass) as toast;
```

- `raw_json` を書き換えない UPDATE は TOAST を再利用するため、メトリクスカラムの
  バックフィル（下記 9 章）で膨らむのは heap 側だけです
- なお `raw_json` は 1 サンプル分の全 GPU 分の XML を各行に重複保存しています。
  保持期間の短縮や、`raw_json` を古い行から `NULL` にする運用が最も効きます
- 温度監視目的だけなら、保持期間/インデックス/パーティション等の DB 側設計を検討してください

### 8.4 DB を全消去してやり直したい

収集中の再流入を避けるため、systemd を止めてから `TRUNCATE` してください。

```bash
systemctl --user stop gpu-telemetry.service
systemctl --user stop gpu-telemetry-flush.timer

set -a
source ${HOME}/projects/gpu-telemetry/.env
set +a

psql "host=$PGHOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER sslmode=${PGSSLMODE:-prefer}" \
  -v ON_ERROR_STOP=1 \
  -c "TRUNCATE telemetry.gpu_telemetry;"
```


### 8.5 サンプリング間隔が設定値より長い

`SAMPLE_INTERVAL_SEC` を 5 にしていても、実測の間隔がそれより大幅に長くなることがある。
まず実測する。

```sql
select date_trunc('hour', ts) as hr,
       count(*)                                  as samples,
       round(3600.0 / count(*), 1)               as avg_interval_sec,
       round(extract(epoch from max(gap))::numeric, 1) as max_gap_sec
from (select ts, ts - lag(ts) over (order by ts) as gap
      from telemetry.gpu_telemetry
      where host = 'x1ai' and pci_bus_id = '00000000:01:00.0'
        and ts >= now() - interval '6 hours') t
group by 1 order by 1;
```

**最も多い原因は `REMOTE_HOSTS` のうち1台が到達不能になっていること。**
`bin/collect_loop.sh` は各ホストを並列に収集し、`bin/collect_once.py` の SSH には
`ConnectTimeout=5` を設定しているため、1台が落ちても他ホストのサンプルは遅れない。

ただし ~/.ssh/config 側に `ConnectTimeout` が無い状態で逐次収集していた頃は、到達不能な
ホスト1台が OS の TCP タイムアウト（約130秒）までループ全体をブロックしていた。
**2026-08-30 に実際に発生**: `precision3680-wsl` の Tailscale 改称中、サンプル間隔が
5 秒から約144秒（最大ギャップ973秒）に劣化し、同時刻に実施していたファン冷却検証の
温度データが使い物にならない解像度になった。

到達性の確認:

```bash
for h in ${REMOTE_HOSTS}; do
  echo -n "$h: "; timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" 'echo ok' || echo NG
done
journalctl --user -u gpu-telemetry.service --since '1 hour ago' | grep WARN
```

到達不能ホストは `[WARN] nvidia-smi collection failed for host=...` として1行だけ記録され、
トレースバックは出ない。
## 9. メトリクスカラムのバックフィル

`gpu_util_pct` / `mem_used_mib` / `power_w` / `perf_state` / `processes` などのカラムは
`sql/002_add_metric_columns.sql` で追加されました。それ以前に収集した行では NULL です。

値そのものは `raw_json` の XML に入っているので、後から再計算できます。抽出は
サーバ側の xpath / XMLTABLE で行うため、40 GB の XML をクライアントに転送しません。

```bash
# 何行が未充填かだけ確認する
uv run ./bin/backfill_metrics.py --dry-run

# 直近 30 日だけ
uv run ./bin/backfill_metrics.py --since 2026-08-01T00:00:00+00:00

# 全期間（実測 約4.8 ms/行。500万行で 3〜4 時間かかるので nohup 等で流す）
nohup uv run ./bin/backfill_metrics.py --batch-minutes 60 > logs/backfill_metrics.log 2>&1 &

# 中断した場合は checkpoint から再開
uv run ./bin/backfill_metrics.py --resume
```

- 対象は `gpu_util_pct IS NULL` の行のみなので、何度実行しても安全です
- checkpoint は `logs/backfill_metrics_checkpoint.json` の 1 ファイルを上書き更新します
- 進捗は `[N/M] ... elapsed=Xs eta=Ys` 形式で標準出力に出ます
- パースに失敗した時間窓はスキップして続行し、完了時に `failed_windows` として件数を報告します

### 進捗確認

```sql
select count(*) filter (where gpu_util_pct is not null) as filled,
       count(*)                                         as total,
       round(100.0 * count(*) filter (where gpu_util_pct is not null) / count(*), 2) as pct
from telemetry.gpu_telemetry;
```
