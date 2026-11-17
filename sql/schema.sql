-- TradeLedger AI — multi-tenant schema (sanitized public version)
--
-- Derived from the production schema. Credential storage and billing columns are
-- intentionally omitted; vendor-specific names are generalized.
-- Requires PostgreSQL 13+ (gen_random_uuid() is built in).
--
-- Tables are listed in dependency order so this file replays cleanly on an empty database.

-- ============================================================
-- tenants: one row per customer company
-- ============================================================
CREATE TABLE tenants (
  id                        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  company_name              text        NOT NULL,
  sms_number                text        NOT NULL UNIQUE,   -- E.164; inbound messages are routed to a tenant by this
  accounting_realm_id       text,                          -- tenant's company id in the accounting system
  credentials_rotated_at    timestamptz DEFAULT now(),     -- drives the dormancy monitor
  default_payment_method    text        NOT NULL DEFAULT 'card'
                              CHECK (default_payment_method IN ('card', 'cash', 'personal')),
  default_card_account_id   text,
  default_card_account_name text,
  default_gl_account_id     text,                          -- fallback expense account
  default_gl_account_name   text,
  overhead_project_id       uuid,                          -- soft reference to projects.id (office / general overhead)
  bookkeeper_email          text,
  owner_email               text,
  owner_mobile              text,
  is_active                 boolean     NOT NULL DEFAULT true,
  created_at                timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- projects: synced from the accounting system; aliases feed fuzzy job matching
-- ============================================================
CREATE TABLE projects (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  accounting_project_id text        NOT NULL,
  project_name          text        NOT NULL,
  name_aliases          text[],
  is_active             boolean     NOT NULL DEFAULT true,
  last_synced_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, accounting_project_id)                -- enables idempotent upsert during sync
);

-- ============================================================
-- workers: registered senders, identified by mobile number
-- ============================================================
CREATE TABLE workers (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  mobile_number           text        NOT NULL,
  worker_name             text,
  is_active               boolean     NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  accounting_employee_id  text,
  UNIQUE (tenant_id, mobile_number)
);

-- ============================================================
-- expense_account_map: standard categories -> each tenant's own chart of accounts
-- ============================================================
CREATE TABLE expense_account_map (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  category                text NOT NULL
                            CHECK (category IN ('materials', 'tools', 'fuel', 'subcontractor',
                                                'equipment_rental', 'permits', 'other')),
  accounting_account_id   text NOT NULL,
  accounting_account_name text NOT NULL,
  UNIQUE (tenant_id, category)
);

-- ============================================================
-- receipts: core operational table, one row per submission
-- ============================================================
CREATE TABLE receipts (
  id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                uuid        NOT NULL REFERENCES tenants(id),
  worker_id                uuid        REFERENCES workers(id),   -- NULL for unregistered senders
  message_sid              text        NOT NULL UNIQUE,          -- gateway message id; makes webhook retries safe
  storage_path             text,
  image_hash               text,                                  -- SHA-256 of the image bytes
  raw_message_body         text,

  extracted_vendor         text,
  extracted_amount         numeric(10,2),
  extracted_subtotal       numeric(10,2),
  extracted_tax            numeric(10,2),
  extracted_date           date,
  extracted_category       text,
  extraction_confidence    numeric(4,3),
  extraction_raw           jsonb,                                 -- full model response, kept for audit

  project_id               uuid        REFERENCES projects(id),
  payment_method           text        CHECK (payment_method IN ('card', 'cash', 'personal')),
  accounting_account_id    text,
  accounting_account_name  text,
  accounting_txn_id        text,
  accounting_txn_type      text        CHECK (accounting_txn_type IN ('Expense', 'Bill')),
  accounting_attachment_id text,

  status                   text        NOT NULL DEFAULT 'received'
                             CHECK (status IN ('received', 'downloading', 'extracting', 'disambiguating',
                                               'pending_manual_review', 'posting', 'posted',
                                               'posted_no_attachment', 'failed', 'duplicate')),
  failure_reason           text,
  retry_count              integer     NOT NULL DEFAULT 0,
  submitted_at             timestamptz NOT NULL DEFAULT now(),
  posted_at                timestamptz
);

-- Idempotency: the same image from the same tenant is a duplicate.
CREATE UNIQUE INDEX idx_receipts_dedup
  ON receipts (image_hash, tenant_id)
  WHERE image_hash IS NOT NULL;

-- ============================================================
-- disambiguation_sessions: pending job-selection state between workflows
-- ============================================================
CREATE TABLE disambiguation_sessions (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id          uuid        NOT NULL UNIQUE REFERENCES receipts(id),   -- one open session per receipt
  tenant_id           uuid        NOT NULL REFERENCES tenants(id),
  worker_mobile       text        NOT NULL,
  options_presented   jsonb       NOT NULL,   -- [{"key":"1","project_id":"...","label":"..."}, ...]
  expires_at          timestamptz NOT NULL DEFAULT (now() + interval '16 hours'),
  resolved_at         timestamptz,
  resolved_project_id uuid        REFERENCES projects(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- timesheets (feature-flagged off in the current release)
-- ============================================================
CREATE TABLE timesheets (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid         NOT NULL REFERENCES tenants(id),
  worker_id      uuid         NOT NULL REFERENCES workers(id),
  project_id     uuid         REFERENCES projects(id),
  clock_in_at    timestamptz,
  clock_out_at   timestamptz,
  duration_hours numeric(5,2) GENERATED ALWAYS AS (
    CASE
      WHEN clock_in_at IS NOT NULL AND clock_out_at IS NOT NULL
        THEN round(EXTRACT(epoch FROM (clock_out_at - clock_in_at)) / 3600.0, 2)
      ELSE NULL
    END
  ) STORED,
  accounting_time_activity_id text,
  status         text         NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'closed', 'posted', 'failed')),
  created_at     timestamptz  NOT NULL DEFAULT now(),
  failure_reason text
);

-- ============================================================
-- Partial indexes: only the small subset of rows that is actually queried
-- ============================================================
CREATE INDEX idx_tenants_active   ON tenants (is_active)                WHERE is_active;
CREATE INDEX idx_projects_active  ON projects (tenant_id)               WHERE is_active;
CREATE INDEX idx_sessions_pending ON disambiguation_sessions (worker_mobile, tenant_id)
                                                                         WHERE resolved_at IS NULL;
CREATE INDEX idx_timesheets_open  ON timesheets (worker_id)             WHERE status = 'open';

-- Receipt lookups
CREATE INDEX idx_receipts_tenant    ON receipts (tenant_id);
CREATE INDEX idx_receipts_status    ON receipts (status);
CREATE INDEX idx_receipts_submitted ON receipts (submitted_at DESC);

-- ============================================================
-- Row-level security: enabled on every table, with no policies defined.
-- Result: direct client access (anon / authenticated roles) is denied by default;
-- trusted server-side roles bypass RLS.
-- ============================================================
ALTER TABLE tenants                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects                ENABLE ROW LEVEL SECURITY;
ALTER TABLE workers                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_account_map     ENABLE ROW LEVEL SECURITY;
ALTER TABLE receipts                ENABLE ROW LEVEL SECURITY;
ALTER TABLE disambiguation_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE timesheets              ENABLE ROW LEVEL SECURITY;
