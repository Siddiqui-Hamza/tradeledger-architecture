-- Weekly digest data for a tenant, returned as JSON.
-- Aggregation only: email layout/presentation is handled outside the database.
CREATE OR REPLACE FUNCTION weekly_digest_stats(p_tenant uuid, p_week_start timestamptz)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH posted AS (
    SELECT r.id, r.worker_id, r.project_id, r.extracted_amount, r.submitted_at
    FROM receipts r
    WHERE r.tenant_id = p_tenant
      AND r.status IN ('posted', 'posted_no_attachment')
  ),
  per_job AS (
    SELECT
      COALESCE(p.project_name, 'Office / General')                           AS job,
      COUNT(*) FILTER (WHERE x.submitted_at >= p_week_start)                 AS week_receipts,
      COALESCE(SUM(x.extracted_amount)
               FILTER (WHERE x.submitted_at >= p_week_start), 0)             AS week_amount,
      COUNT(*)                                                               AS lifetime_receipts,
      COALESCE(SUM(x.extracted_amount), 0)                                   AS lifetime_amount
    FROM posted x
    LEFT JOIN projects p ON p.id = x.project_id
    GROUP BY p.project_name
    HAVING COUNT(*) FILTER (WHERE x.submitted_at >= p_week_start) > 0
  ),
  worker_activity AS (
    SELECT
      COALESCE(w.worker_name, w.mobile_number) AS worker,
      COUNT(x.id)                              AS receipts
    FROM workers w
    LEFT JOIN posted x
           ON x.worker_id = w.id
          AND x.submitted_at >= p_week_start
    WHERE w.tenant_id = p_tenant
      AND w.is_active
    GROUP BY w.id, w.worker_name, w.mobile_number
  )
  SELECT jsonb_build_object(
    'jobs',              COALESCE((SELECT jsonb_agg(to_jsonb(j) ORDER BY j.week_amount DESC)
                                     FROM per_job j), '[]'::jsonb),
    'workers',           COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.receipts DESC)
                                     FROM worker_activity a), '[]'::jsonb),
    'active_workers',    (SELECT COUNT(*) FROM worker_activity WHERE receipts > 0),
    'total_workers',     (SELECT COUNT(*) FROM worker_activity),
    'week_total',        (SELECT COALESCE(ROUND(SUM(extracted_amount), 2), 0)
                            FROM posted WHERE submitted_at >= p_week_start),
    'lifetime_receipts', (SELECT COUNT(*) FROM posted),
    'lifetime_total',    (SELECT COALESCE(ROUND(SUM(extracted_amount), 2), 0) FROM posted)
  );
$$;
