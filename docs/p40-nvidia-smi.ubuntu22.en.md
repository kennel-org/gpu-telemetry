# Bring up Tesla P40 on Ubuntu 22.04 until `nvidia-smi` works (X1 AI + DEG1 eGPU)

This document focuses only on getting a Tesla P40 (connected via an eGPU dock / Oculink) recognized by `nvidia-smi` on Ubuntu 22.04.

- Goal: make the GPU visible to the OS + NVIDIA driver.
- For `gpu-telemetry` setup and DB ingestion, see `docs/operations.en.md`.

## 0. Hardware assumptions

- **Host**: Minisforum X1 AI
- **eGPU dock**: Minisforum DEG1 (Oculink)
- **GPU**: NVIDIA Tesla P40 (requires external power; data-center oriented and assumes chassis airflow; no onboard fan)
- **PSU**: ATX PSU (e.g. 600W)

Important:

- Tesla P40 is designed for data-center use and **assumes chassis airflow** (case fans / ducting). Keep initial checks short, and never run load without adequate airflow.

## 1. Physical checks (must pass before anything else)

- Confirm **8-pin auxiliary power** is firmly connected.
- Confirm the P40 is fully seated in the DEG1 PCIe slot (latch/lock).
- Reseat the Oculink cable on both ends.
- Confirm PSU is stable (some setups require a jumper / switch / PS_ON wiring).

Typical symptom:

- If `lspci` does not show NVIDIA at all, it is almost always physical or BIOS/UEFI configuration.

## 2. BIOS/UEFI settings (important before Ubuntu)

Menu names vary by vendor. The intent is:

- ensure enough PCIe/MMIO resources for a large PCIe device
- avoid DKMS/module signing issues
- improve eGPU link stability

Recommended (stability-first):

- **Secure Boot: OFF**
- **Above 4G Decoding: ON**
- **Re-Size BAR: Auto / OFF** (enable only if known-good)
- **PCIe ASPM: OFF**

Useful logs on Ubuntu:

```bash
sudo dmesg -T | egrep -i 'pcie|aer|mmio|resource|iommu|nvrm|nvidia|nouveau' | tail -n 200
```

## 3. Confirm the GPU is visible as a PCIe device

### 3.1 `lspci`

```bash
lspci -nn | egrep -i 'nvidia|3d|vga' || true
lspci -nnk | egrep -A3 -i 'nvidia|3d|vga' || true
```

- If the GPU does not appear here, go back to **physical checks** and **Above 4G Decoding**.

### 3.2 PCIe link width/speed

```bash
GPU_BDF="$(lspci | awk '/NVIDIA/{print $1; exit}')"
if [ -n "$GPU_BDF" ]; then
  sudo lspci -vv -s "$GPU_BDF" | egrep -i 'LnkCap|LnkSta' || true
fi
```

## 4. Install NVIDIA driver on Ubuntu 22.04

### 4.1 Check for nouveau

```bash
lsmod | egrep '^nouveau' || true
```

If `nouveau` is loaded, disable it.

### 4.2 Disable nouveau (if needed)

```bash
sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

sudo update-initramfs -u
sudo reboot
```

After reboot, confirm `lsmod | grep nouveau` is empty.

### 4.3 Recommended: use `ubuntu-drivers`

```bash
sudo apt update
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices

sudo ubuntu-drivers autoinstall
sudo reboot
```

### 4.4 Manual driver install (example)

Depending on your repo state, a common stable choice on 22.04 is 535-series.

```bash
sudo apt update
sudo apt install -y nvidia-driver-535
sudo reboot
```

### 4.5 If Secure Boot is the blocker

If Secure Boot is ON, DKMS modules may build but fail to load.

- Recommended: **disable Secure Boot in BIOS**
- Alternative: MOK enrollment (policy-dependent)

Check state:

```bash
mokutil --sb-state || true
```

## 5. Verify success

### 5.1 Module check

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

Success criteria:

- `nvidia-smi` lists `Tesla P40`
- Driver version is shown
- Temperature/utilization/VRAM can be queried

## 6. Common failure patterns

### 6.1 NVIDIA does not appear in `lspci`

Most likely:

- power/cable/seating/PSU issues
- BIOS resource config (Above 4G Decoding)

### 6.2 `lspci` shows NVIDIA but `nvidia-smi` says `No devices were found`

Likely:

- nouveau conflict
- NVIDIA module not loaded
- Secure Boot blocking module load

Check:

```bash
lsmod | egrep 'nouveau|nvidia' || true
sudo dmesg -T | egrep -i 'nvrm|nvidia|nouveau' | tail -n 200
```

### 6.3 `nvidia-smi` hangs/timeouts

Likely:

- unstable PCIe link (ASPM, cabling)
- PSU instability
- insufficient cooling

Check:

```bash
sudo journalctl -k -b | egrep -i 'nvrm|pcie|aer' | tail -n 200
```
