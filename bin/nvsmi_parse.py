#!/usr/bin/env python3
"""Extract per-GPU metrics from `nvidia-smi -q -x` output.

collect_once.py and flush_spool.py both go through here so that the metric
columns are derived from exactly one place. bin/backfill_metrics.py reads the
same XML fields, but server-side in SQL, to avoid pulling the archive over the
wire.
"""
import xml.etree.ElementTree as ET

# Driver 570-ish renamed <power_draw> to <instant_power_draw> inside
# <gpu_power_readings>; rows collected before the upgrade still use the old tag.
POWER_PATHS = (
    "gpu_power_readings/instant_power_draw",
    "gpu_power_readings/power_draw",
    "power_readings/power_draw",
)


def _text(elem, path: str) -> str | None:
    """Value at path, with nvidia-smi's "N/A" placeholder folded to None."""
    if elem is None:
        return None
    found = elem.find(path)
    if found is None or found.text is None:
        return None
    value = found.text.strip()
    return None if value in ("", "N/A", "Unknown Error") else value


def _num(elem, path: str, cast=int):
    """Leading number at path ("22067 MiB" -> 22067, "49.09 W" -> 49.09)."""
    value = _text(elem, path)
    if value is None:
        return None
    try:
        return cast(value.split()[0])
    except (ValueError, IndexError):
        return None


def _power_w(gpu) -> float | None:
    for path in POWER_PATHS:
        watts = _num(gpu, path, float)
        if watts is not None:
            return watts
    return None


def _processes(gpu) -> list[dict]:
    out = []
    for proc in gpu.findall("processes/process_info"):
        pid = _num(proc, "pid")
        if pid is None:
            continue
        out.append(
            {
                "pid": pid,
                "type": _text(proc, "type"),
                "name": _text(proc, "process_name"),
                "used_mib": _num(proc, "used_memory"),
            }
        )
    out.sort(key=lambda p: p["pid"])
    return out


def strip_prolog_noise(raw_xml: str) -> str:
    """Drop plain-text nvidia-smi errors printed before the XML declaration.

    When a GPU falls off the bus, `nvidia-smi -q -x` still exits 0 but prefixes the
    document with e.g. "Unable to determine the device handle for GPU0: 0000:01:00.0:
    Unknown Error", which makes it unparseable. The XML that follows is well formed,
    and it is exactly the sample worth keeping, so recover it rather than dropping it.
    Seen on 2026-03-30 for ~12 hours (5,448 samples).
    """
    for marker in ("<?xml", "<nvidia_smi_log"):
        i = raw_xml.find(marker)
        if i > 0:
            return raw_xml[i:]
        if i == 0:
            return raw_xml
    return raw_xml


def metrics_by_uuid(raw_xml: str) -> dict[str, dict]:
    """Map GPU UUID -> metric dict for every <gpu> block in the snapshot.

    Returns an empty mapping if the XML cannot be parsed, so that a malformed
    snapshot degrades to NULL metric columns rather than dropping the sample.
    """
    try:
        root = ET.fromstring(strip_prolog_noise(raw_xml))
    except ET.ParseError:
        return {}

    result = {}
    for gpu in root.findall("gpu"):
        gpu_uuid = _text(gpu, "uuid")
        if gpu_uuid is None:
            continue
        result[gpu_uuid] = {
            "gpu_util_pct": _num(gpu, "utilization/gpu_util"),
            "mem_util_pct": _num(gpu, "utilization/memory_util"),
            "mem_used_mib": _num(gpu, "fb_memory_usage/used"),
            "mem_total_mib": _num(gpu, "fb_memory_usage/total"),
            "power_w": _power_w(gpu),
            "fan_pct": _num(gpu, "fan_speed"),
            "sm_clock_mhz": _num(gpu, "clocks/sm_clock"),
            "perf_state": _text(gpu, "performance_state"),
            "processes": _processes(gpu),
        }
    return result


EMPTY_METRICS = {
    "gpu_util_pct": None,
    "mem_util_pct": None,
    "mem_used_mib": None,
    "mem_total_mib": None,
    "power_w": None,
    "fan_pct": None,
    "sm_clock_mhz": None,
    "perf_state": None,
    "processes": None,
}

# Column order shared by the insert statements in collect_once.py / flush_spool.py.
METRIC_COLUMNS = (
    "gpu_util_pct",
    "mem_util_pct",
    "mem_used_mib",
    "mem_total_mib",
    "power_w",
    "fan_pct",
    "sm_clock_mhz",
    "perf_state",
    "processes",
)
