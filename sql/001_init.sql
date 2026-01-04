-- Initial schema for GPU telemetry (safe to run on fresh or partially prepared DB)

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS telemetry;

CREATE TABLE IF NOT EXISTS telemetry.gpu_telemetry (
  ts          timestamptz not null,
  host        text        not null,
  gpu_uuid    text        not null,
  pci_bus_id  text        not null,
  gpu_name    text,
  temp_c      int,
  status_tag  text,
  status_memo text,
  raw_json    jsonb       not null,
  PRIMARY KEY (ts, host, gpu_uuid)
);

CREATE INDEX IF NOT EXISTS gpu_telemetry_host_ts_idx
  ON telemetry.gpu_telemetry (host, ts DESC);

CREATE INDEX IF NOT EXISTS gpu_telemetry_ts_idx
  ON telemetry.gpu_telemetry (ts DESC);

CREATE INDEX IF NOT EXISTS gpu_telemetry_status_tag_ts_idx
  ON telemetry.gpu_telemetry (status_tag, ts DESC);
