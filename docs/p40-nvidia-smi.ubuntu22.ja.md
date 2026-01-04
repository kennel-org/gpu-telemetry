# Tesla P40 を Ubuntu 22.04 で `nvidia-smi` に認識させるまで（X1 AI + DEG1 eGPU）

このドキュメントは、Tesla P40 を eGPU（DEG1/Oculink）経由で接続した Ubuntu 22.04 ホストで、`nvidia-smi` が GPU を認識するところまでに絞った手順です。

- 目的は「OS/ドライバの観点で GPU を見える状態にする」ことです。
- `gpu-telemetry` 自体のセットアップや DB 投入は `docs/operations.ja.md` を参照してください。

## 0. 前提（ハード）

- **Host**: Minisforum X1 AI
- **eGPU**: Minisforum DEG1（Oculink）
- **GPU**: NVIDIA Tesla P40（補助電源必須 / DC向け。筐体エアフロー前提でオンボードファン無し）
- **電源**: ATX PSU（600W など）

重要:

- P40 は DC 向けで **筐体の空冷（ケースファン/ダクト）前提**の設計です。送風が無い構成では動作確認も短時間に留め、ベンチ/長時間運用は必ず十分なエアフローを確保してください。

## 1. 物理確認（ここで詰むと以降は無意味）

- **補助電源（8-pin）** が確実に刺さっていること
- DEG1 側の PCIe スロットに **奥まで挿さってロックされていること**
- Oculink ケーブルを **抜き差し**して接触不良を潰すこと
- PSU が安定して起動していること（構成によりジャンパやスイッチが必要）

### 典型的な症状

- `lspci` に NVIDIA が出ない
  - 物理（電源/ケーブル/挿し込み）か BIOS 設定の問題の可能性が高いです。

## 2. BIOS/UEFI 設定（Ubuntu 22.04 以前に重要）

機種により項目名は異なりますが、狙いは「大きい PCIe デバイスを載せてもリソース不足にしない」「セキュリティ機構で DKMS を弾かない」です。

推奨（安定性重視）:

- **Secure Boot: OFF**
  - Ubuntu の NVIDIA ドライバ（DKMS）が署名/ロードできず `nvidia-smi` が失敗するケースを回避
- **Above 4G Decoding: ON**
  - eGPU/大容量 VRAM での MMIO/リソース不足回避
- **Re-Size BAR: Auto / OFF**
  - まずは安定優先（動作が安定するなら ON でも可）
- **PCIe ASPM: OFF**
  - eGPU リンク不安定の回避

確認に使うログ（Ubuntu）:

```bash
sudo dmesg -T | egrep -i 'pcie|aer|mmio|resource|iommu|nvrm|nvidia|nouveau' | tail -n 200
```

## 3. ドライバより先に「PCIe として見えているか」を確認

### 3.1 `lspci` に NVIDIA が出るか

```bash
lspci -nn | egrep -i 'nvidia|3d|vga' || true
lspci -nnk | egrep -A3 -i 'nvidia|3d|vga' || true
```

- ここで NVIDIA が出ない場合は、**物理**または **BIOS（Above 4G）**に戻ってください。

### 3.2 PCIe リンク状態（落ちていないか）

```bash
GPU_BDF="$(lspci | awk '/NVIDIA/{print $1; exit}')"
if [ -n "$GPU_BDF" ]; then
  sudo lspci -vv -s "$GPU_BDF" | egrep -i 'LnkCap|LnkSta' || true
fi
```

## 4. Ubuntu 22.04 での NVIDIA ドライバ導入（推奨手順）

### 4.1 nouveau の競合確認

```bash
lsmod | egrep '^nouveau' || true
```

もし `nouveau` がロードされているなら、まず無効化します。

### 4.2 nouveau を無効化（必要な場合）

```bash
sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

sudo update-initramfs -u
sudo reboot
```

再起動後に `lsmod | grep nouveau` が空になることを確認します。

### 4.3 推奨: `ubuntu-drivers` でドライバを選ぶ

```bash
sudo apt update
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices
```

推奨版が表示されるので、基本は自動導入が簡単です。

```bash
sudo ubuntu-drivers autoinstall
sudo reboot
```

### 4.4 手動でバージョン指定する場合（例）

リポジトリ状況により推奨版が変わります。例として 22.04 では 535 系が安定運用しやすいことが多いです。

```bash
sudo apt update
sudo apt install -y nvidia-driver-535
sudo reboot
```

### 4.5 Secure Boot が原因でロードできない場合

Secure Boot が ON だと、DKMS でビルドされてもモジュールがロードできず失敗することがあります。

- 可能なら **BIOS で Secure Boot を OFF**（推奨）
- もしくは MOK 登録（運用ポリシー次第）

状態確認:

```bash
mokutil --sb-state || true
```

## 5. 最終確認（成功基準）

### 5.1 モジュール確認

```bash
lsmod | egrep '^nvidia' || true
modinfo -F version nvidia || true
```

### 5.2 `nvidia-smi`

```bash
nvidia-smi
nvidia-smi -L
nvidia-smi --query-gpu=name,driver_version,pci.bus_id,temperature.gpu,utilization.gpu,memory.total --format=csv
```

成功の目安:

- `nvidia-smi` の一覧に `Tesla P40` が出る
- driver version が表示される
- 温度/利用率/VRAM が取得できる

## 6. よくある失敗パターン

### 6.1 `lspci` に NVIDIA が出ない

- 物理（補助電源/ケーブル/挿し込み/PSU）
- BIOS（Above 4G Decoding）

が最優先です。

### 6.2 `lspci` は出るが `nvidia-smi` が `No devices were found`

原因候補:

- `nouveau` 競合
- NVIDIA モジュール未ロード
- Secure Boot で DKMS モジュールが弾かれている

確認:

```bash
lsmod | egrep 'nouveau|nvidia' || true
sudo dmesg -T | egrep -i 'nvrm|nvidia|nouveau' | tail -n 200
```

### 6.3 `nvidia-smi` がハング/タイムアウト

原因候補:

- PCIe リンク不安定（ASPM 等）
- 電源不足/不安定
- 冷却不足（P40 は無風だと厳しい）

確認:

```bash
sudo journalctl -k -b | egrep -i 'nvrm|pcie|aer' | tail -n 200
```
