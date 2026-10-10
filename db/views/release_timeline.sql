CREATE VIEW release_timeline AS
SELECT
  slug, state, created_at, updated_at,
  testing_started_at, tested_at,
  assembling_started_at, assembled_at,
  qa_deploy_started_at, qa_deployed_at,
  confirming_started_at, confirmed_at,
  prod_deploy_started_at, shipped_at,
  abandoned_at, duration_metrics_cached_at
FROM releases
