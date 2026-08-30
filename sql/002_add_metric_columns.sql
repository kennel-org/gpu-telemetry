-- Promote the metrics Grafana needs out of raw_json into real columns.
--
-- raw_json holds the whole `nvidia-smi -q -x` XML as a string, so panels cannot
-- query it. Generated columns are not an option either: casting text to xml goes
-- through xml_in, which is STABLE rather than IMMUTABLE, and GENERATED ALWAYS AS
-- ... STORED only accepts immutable expressions. So these are plain columns,
-- filled by the collector on insert and by bin/backfill_metrics.py for history.
--
-- All columns are nullable with no default, which keeps this a metadata-only
-- ALTER (no table rewrite) even on the existing multi-GB table.

ALTER TABLE telemetry.gpu_telemetry
  ADD COLUMN IF NOT EXISTS gpu_util_pct  smallint,
  ADD COLUMN IF NOT EXISTS mem_util_pct  smallint,
  ADD COLUMN IF NOT EXISTS mem_used_mib  integer,
  ADD COLUMN IF NOT EXISTS mem_total_mib integer,
  ADD COLUMN IF NOT EXISTS power_w       numeric(7,2),
  ADD COLUMN IF NOT EXISTS fan_pct       smallint,
  ADD COLUMN IF NOT EXISTS sm_clock_mhz  integer,
  ADD COLUMN IF NOT EXISTS perf_state    text,
  -- [{"pid":123,"type":"C","name":"/path/to/bin","used_mib":19710}, ...]
  ADD COLUMN IF NOT EXISTS processes     jsonb;

COMMENT ON COLUMN telemetry.gpu_telemetry.processes IS
  'Per-GPU process list from nvidia-smi -q -x; type C = compute, G = graphics.';

-- Supports "which run was hogging VRAM" lookups by process name.
CREATE INDEX IF NOT EXISTS gpu_telemetry_processes_gin_idx
  ON telemetry.gpu_telemetry USING gin (processes jsonb_path_ops);
