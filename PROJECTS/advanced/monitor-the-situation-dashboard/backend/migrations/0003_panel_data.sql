-- ©AngelaMos | 2026
-- 0003_panel_data.sql

-- +goose Up
-- +goose StatementBegin
CREATE TABLE cve_events (
    cve_id          text PRIMARY KEY,
    published       timestamptz,
    last_modified   timestamptz NOT NULL,
    severity        text,
    cvss_score      numeric(3,1),
    epss_score      numeric(5,4),
    epss_percentile numeric(5,4),
    in_kev          boolean NOT NULL DEFAULT false,
    payload         jsonb NOT NULL
);
CREATE INDEX idx_cve_lastmod_brin     ON cve_events USING BRIN (last_modified);
CREATE INDEX idx_cve_severity_lastmod ON cve_events (severity, last_modified DESC);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE kev_entries (
    cve_id              text PRIMARY KEY,
    vendor              text,
    product             text,
    vulnerability_name  text,
    date_added          date NOT NULL,
    due_date            date,
    ransomware_use      text,
    payload             jsonb NOT NULL
);
CREATE INDEX idx_kev_dateadded ON kev_entries (date_added DESC);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE earthquakes (
    id              text PRIMARY KEY,
    occurred_at     timestamptz NOT NULL,
    mag             numeric(3,1) NOT NULL,
    place           text,
    geom_lon        double precision NOT NULL,
    geom_lat        double precision NOT NULL,
    depth_km        double precision,
    payload         jsonb NOT NULL
);
CREATE INDEX idx_quakes_time_brin ON earthquakes USING BRIN (occurred_at);
CREATE INDEX idx_quakes_mag       ON earthquakes (mag DESC, occurred_at DESC);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE ransomware_victims (
    id              text PRIMARY KEY,
    post_title      text NOT NULL,
    group_name      text NOT NULL,
    discovered_at   timestamptz NOT NULL,
    country         text,
    sector          text,
    payload         jsonb NOT NULL
);
CREATE INDEX idx_rans_time_brin ON ransomware_victims USING BRIN (discovered_at);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE btc_eth_ticks (
    symbol      text NOT NULL,
    ts          timestamptz NOT NULL,
    price       numeric(18,8) NOT NULL,
    volume_24h  numeric(20,8),
    PRIMARY KEY (symbol, ts)
);
CREATE INDEX idx_ticks_time_brin ON btc_eth_ticks USING BRIN (ts);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE btc_eth_minute (
    symbol  text NOT NULL,
    minute  timestamptz NOT NULL,
    open    numeric(18,8) NOT NULL,
    high    numeric(18,8) NOT NULL,
    low     numeric(18,8) NOT NULL,
    close   numeric(18,8) NOT NULL,
    volume  numeric(20,8),
    PRIMARY KEY (symbol, minute)
);
CREATE INDEX idx_minute_time_brin ON btc_eth_minute USING BRIN (minute);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE outage_events (
    id          text PRIMARY KEY,
    started_at  timestamptz NOT NULL,
    ended_at    timestamptz,
    locations   text[] NOT NULL DEFAULT '{}',
    asns        integer[] NOT NULL DEFAULT '{}',
    cause       text,
    outage_type text,
    payload     jsonb NOT NULL
);
CREATE INDEX idx_outage_start_brin ON outage_events USING BRIN (started_at);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE bgp_hijack_events (
    id            bigint PRIMARY KEY,
    detected_at   timestamptz NOT NULL,
    started_at    timestamptz NOT NULL,
    duration_sec  integer,
    confidence    smallint,
    hijacker_asn  integer,
    victim_asns   integer[] NOT NULL DEFAULT '{}',
    prefixes      cidr[] NOT NULL DEFAULT '{}',
    payload       jsonb NOT NULL
);
CREATE INDEX idx_hijack_time_brin ON bgp_hijack_events USING BRIN (detected_at);
CREATE INDEX idx_hijack_conf_time ON bgp_hijack_events (confidence DESC, detected_at DESC);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE dshield_snapshots (
    ts        timestamptz NOT NULL,
    kind      text NOT NULL,
    payload   jsonb NOT NULL,
    PRIMARY KEY (ts, kind)
);
CREATE INDEX idx_dshield_ts_brin ON dshield_snapshots USING BRIN (ts);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE world_events (
    id              text PRIMARY KEY,
    source          text NOT NULL,
    occurred_at     timestamptz NOT NULL,
    headline        text NOT NULL,
    payload         jsonb NOT NULL
);
CREATE INDEX idx_world_time_brin ON world_events USING BRIN (occurred_at);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS world_events;
DROP TABLE IF EXISTS dshield_snapshots;
DROP TABLE IF EXISTS bgp_hijack_events;
DROP TABLE IF EXISTS outage_events;
DROP TABLE IF EXISTS btc_eth_minute;
DROP TABLE IF EXISTS btc_eth_ticks;
DROP TABLE IF EXISTS ransomware_victims;
DROP TABLE IF EXISTS earthquakes;
DROP TABLE IF EXISTS kev_entries;
DROP TABLE IF EXISTS cve_events;
-- +goose StatementEnd
