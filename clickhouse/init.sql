-- One row per jsonl line (see push-results.sh). ReplacingMergeTree drops
-- identical rows, so pushing the same file twice (watcher restart, a copy in
-- another folder) never duplicates data; queries read with FINAL. When the
-- same row comes both from a published results repo and a local folder, the
-- published copy wins (published = 1).
CREATE TABLE IF NOT EXISTS fleet_scale_results
(
    ts        DateTime,
    metric    LowCardinality(String),
    value     Float64,
    unit      LowCardinality(String),
    run_label String,
    labels    Map(String, String),
    published UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(published)
ORDER BY (metric, run_label, ts, sipHash64(labels), value);

-- Results pushed by hand with push-results.sh (also inserted above). Never
-- rebuilt or cleared: watch-results.sh copies it into every rebuild.
CREATE TABLE IF NOT EXISTS fleet_scale_manual AS fleet_scale_results;
