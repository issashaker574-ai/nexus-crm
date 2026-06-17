-- ================================================================
-- NEXUS CRM — Supabase / PostgreSQL Schema
-- Version: 1.0.0
-- Beschreibung: Kern-Tabellen für Users, Companies, Contacts,
--               POS-Transactions, Error-Logs + SUPER_ADMIN Support
-- ================================================================

-- ----------------------------------------------------------------
-- EXTENSIONS
-- ----------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";      -- Fuzzy-Suche

-- ----------------------------------------------------------------
-- HELPER: updated_at Trigger automatisch setzen
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- 1. ORGANIZATIONS (Mandanten / Workspaces)
--    Jede Firma, die NEXUS nutzt, ist eine Organization.
--    Multi-Tenancy: Alle anderen Tabellen haben org_id.
-- ================================================================
CREATE TABLE public.organizations (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text        NOT NULL,
  slug            text        UNIQUE NOT NULL,                  -- z.B. "meine-firma"
  plan            text        NOT NULL DEFAULT 'starter'
                              CHECK (plan IN ('starter','growth','enterprise')),
  status          text        NOT NULL DEFAULT 'trial'
                              CHECK (status IN ('active','trial','suspended','cancelled')),
  trial_ends_at   timestamptz,
  settings        jsonb       NOT NULL DEFAULT '{}',            -- Theme, Features, etc.
  billing_email   text,
  tax_id          text,                                         -- USt-IdNr.
  country         text        NOT NULL DEFAULT 'DE',
  timezone        text        NOT NULL DEFAULT 'Europe/Berlin',
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  deleted_at      timestamptz                                   -- Soft-Delete
);

CREATE UNIQUE INDEX idx_organizations_slug ON public.organizations(slug)
  WHERE deleted_at IS NULL;

CREATE TRIGGER trg_organizations_updated_at
  BEFORE UPDATE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ================================================================
-- 2. USERS (erweitert auth.users von Supabase)
--    SUPER_ADMIN: Zugriff auf Creator-Dashboard über ALLE Orgs.
--    ADMIN:       Vollzugriff innerhalb einer Org.
--    MANAGER:     Schreibzugriff auf zugewiesene Module.
--    USER:        Standard-Mitarbeiter.
--    VIEWER:      Nur-Lesen.
-- ================================================================
CREATE TABLE public.users (
  id              uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  org_id          uuid        REFERENCES public.organizations(id) ON DELETE SET NULL,
  email           text        NOT NULL,
  full_name       text,
  display_name    text,
  avatar_url      text,
  role            text        NOT NULL DEFAULT 'USER'
                              CHECK (role IN ('SUPER_ADMIN','ADMIN','MANAGER','USER','VIEWER')),
  status          text        NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active','invited','suspended','deleted')),
  department      text,
  job_title       text,
  phone           text,
  language        text        NOT NULL DEFAULT 'de'
                              CHECK (language IN ('de','en','fr','es','tr','ar')),
  theme           text        NOT NULL DEFAULT 'dark'
                              CHECK (theme IN ('dark','light','system')),
  onboarded_at    timestamptz,                                  -- NULL = Onboarding noch nicht abgeschlossen
  last_seen_at    timestamptz,
  invited_by      uuid        REFERENCES public.users(id),
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW()
);

-- Index für schnelle Org-Abfragen
CREATE INDEX idx_users_org_id    ON public.users(org_id);
CREATE INDEX idx_users_role      ON public.users(role);
CREATE INDEX idx_users_email     ON public.users(email);
CREATE INDEX idx_users_status    ON public.users(status);

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ================================================================
-- 3. COMPANIES (CRM — B2B Firmenprofile)
-- ================================================================
CREATE TABLE public.companies (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  -- Stammdaten
  name            text        NOT NULL,
  legal_name      text,                                         -- Offizieller Firmenname
  domain          text,
  website         text,
  logo_url        text,
  industry        text,
  company_size    text
                  CHECK (company_size IN ('1-10','11-50','51-200','201-1000','1000+')),
  employee_count  integer,
  founded_year    integer,
  annual_revenue  numeric(15,2),
  currency        text        NOT NULL DEFAULT 'EUR',

  -- Kontaktdaten
  phone           text,
  email           text,

  -- Adresse
  address_line1   text,
  address_line2   text,
  city            text,
  state           text,
  postal_code     text,
  country         text        NOT NULL DEFAULT 'DE',

  -- CRM
  status          text        NOT NULL DEFAULT 'prospect'
                              CHECK (status IN ('prospect','active','inactive','churned','partner')),
  lifecycle_stage text        NOT NULL DEFAULT 'lead'
                              CHECK (lifecycle_stage IN ('lead','qualified','customer','evangelist')),
  crm_score       integer     NOT NULL DEFAULT 0 CHECK (crm_score BETWEEN 0 AND 100),
  tags            text[]      NOT NULL DEFAULT '{}',
  notes           text,

  -- Steuer / Compliance
  tax_id          text,                                         -- USt-IdNr.
  vat_number      text,

  -- Zuweisung
  owner_id        uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  created_by      uuid        REFERENCES public.users(id) ON DELETE SET NULL,

  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  deleted_at      timestamptz                                   -- Soft-Delete
);

CREATE INDEX idx_companies_org_id   ON public.companies(org_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_companies_status   ON public.companies(org_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_companies_owner    ON public.companies(owner_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_companies_name_trgm ON public.companies USING GIN (name gin_trgm_ops);

CREATE TRIGGER trg_companies_updated_at
  BEFORE UPDATE ON public.companies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ================================================================
-- 4. CONTACTS (CRM — Personen / Leads)
-- ================================================================
CREATE TABLE public.contacts (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  company_id      uuid        REFERENCES public.companies(id) ON DELETE SET NULL,

  -- Stammdaten
  first_name      text        NOT NULL,
  last_name       text        NOT NULL,
  email           text,
  email_secondary text,
  phone           text,
  mobile          text,
  job_title       text,
  department      text,
  avatar_url      text,
  linkedin_url    text,
  birthday        date,
  gender          text        CHECK (gender IN ('male','female','diverse','unknown')),

  -- Adresse (optional, falls privat)
  city            text,
  country         text        DEFAULT 'DE',

  -- CRM / Sales
  status          text        NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active','prospect','inactive','churned','blocked')),
  lifecycle_stage text        NOT NULL DEFAULT 'lead'
                              CHECK (lifecycle_stage IN ('lead','mql','sql','opportunity','customer','evangelist')),
  lead_source     text
                  CHECK (lead_source IN ('google_ads','meta_ads','email','referral','organic_seo',
                                         'cold_outreach','event','website','direct','other')),
  lead_score      integer     NOT NULL DEFAULT 0 CHECK (lead_score BETWEEN 0 AND 100),
  annual_value    numeric(12,2),                                -- Geschätzter Jahreswert

  -- Marketing
  email_opt_in    boolean     NOT NULL DEFAULT false,
  sms_opt_in      boolean     NOT NULL DEFAULT false,
  gdpr_consent_at timestamptz,
  tags            text[]      NOT NULL DEFAULT '{}',
  notes           text,

  -- Tracking
  last_contacted_at timestamptz,
  last_activity_at  timestamptz,

  -- Zuweisung
  owner_id        uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  created_by      uuid        REFERENCES public.users(id) ON DELETE SET NULL,

  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  deleted_at      timestamptz                                   -- Soft-Delete
);

CREATE INDEX idx_contacts_org_id      ON public.contacts(org_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_company_id  ON public.contacts(company_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_status      ON public.contacts(org_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_lead_source ON public.contacts(org_id, lead_source) WHERE deleted_at IS NULL;
CREATE INDEX idx_contacts_owner       ON public.contacts(owner_id) WHERE deleted_at IS NULL;
-- Fuzzy-Suche auf Name und E-Mail
CREATE INDEX idx_contacts_name_trgm   ON public.contacts
  USING GIN ((first_name || ' ' || last_name) gin_trgm_ops);
CREATE INDEX idx_contacts_email_trgm  ON public.contacts USING GIN (email gin_trgm_ops);

CREATE TRIGGER trg_contacts_updated_at
  BEFORE UPDATE ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ================================================================
-- 5. POS_STORES (Standorte / Filialen)
--    Wird von pos_transactions referenziert.
-- ================================================================
CREATE TABLE public.pos_stores (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            text        NOT NULL,                         -- z.B. "Filiale Berlin Mitte"
  code            text        NOT NULL,                         -- z.B. "BER01"
  address         text,
  city            text,
  country         text        NOT NULL DEFAULT 'DE',
  phone           text,
  manager_id      uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  is_online       boolean     NOT NULL DEFAULT false,           -- Online-Shop Flag
  status          text        NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active','inactive','closed')),
  settings        jsonb       NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),

  UNIQUE (org_id, code)
);

CREATE TRIGGER trg_pos_stores_updated_at
  BEFORE UPDATE ON public.pos_stores
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ================================================================
-- 6. POS_PLUGINS (Verbundene externe POS-Systeme)
--    Shopify, Square, SumUp, WooCommerce, DATEV Kassenbuch, etc.
-- ================================================================
CREATE TABLE public.pos_plugins (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  plugin_id       text        NOT NULL,                         -- 'shopify','square','sumup', etc.
  name            text        NOT NULL,
  icon            text,
  category        text,                                         -- 'E-Commerce','Kasse','Buchhaltung'
  is_connected    boolean     NOT NULL DEFAULT false,
  api_key_hash    text,                                         -- GEHASHED — niemals Plaintext!
  api_endpoint    text,
  sync_interval   integer     NOT NULL DEFAULT 15,              -- Minuten
  last_sync_at    timestamptz,
  synced_tx_count integer     NOT NULL DEFAULT 0,
  synced_revenue  numeric(15,2) NOT NULL DEFAULT 0,
  status          text        NOT NULL DEFAULT 'idle'
                              CHECK (status IN ('ok','error','idle','syncing')),
  error_message   text,
  config          jsonb       NOT NULL DEFAULT '{}',            -- Plugin-spezifische Einstellungen
  connected_by    uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),

  UNIQUE (org_id, plugin_id)
);

CREATE INDEX idx_pos_plugins_org_id ON public.pos_plugins(org_id);

CREATE TRIGGER trg_pos_plugins_updated_at
  BEFORE UPDATE ON public.pos_plugins
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ================================================================
-- 7. POS_TRANSACTIONS (Kassenbewegungen aller Kanäle)
-- ================================================================
CREATE TABLE public.pos_transactions (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid        NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  store_id          uuid        REFERENCES public.pos_stores(id) ON DELETE SET NULL,
  plugin_id         uuid        REFERENCES public.pos_plugins(id) ON DELETE SET NULL,
  cashier_id        uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  contact_id        uuid        REFERENCES public.contacts(id) ON DELETE SET NULL,   -- Optionaler Kundenbezug

  -- Referenz
  transaction_ref   text        NOT NULL,                       -- z.B. "SHP-4421", "SQ-1234"
  receipt_number    text,
  source_system     text        NOT NULL DEFAULT 'nexus_pos'
                                CHECK (source_system IN (
                                  'nexus_pos','shopify','square','sumup','lightspeed',
                                  'clover','woocommerce','orderbird','gastrofix',
                                  'datev_kasse','vend','manual'
                                )),

  -- Artikel (JSONB Array)
  -- Beispiel: [{"name":"Sneaker Air Max","qty":1,"unit_price":139,"vat_rate":19,"total":139}]
  items             jsonb       NOT NULL DEFAULT '[]',

  -- Beträge (alle in Hauptwährung)
  subtotal          numeric(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  vat_amount        numeric(12,2) NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  discount_amount   numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tip_amount        numeric(12,2) NOT NULL DEFAULT 0 CHECK (tip_amount >= 0),
  total             numeric(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  currency          text        NOT NULL DEFAULT 'EUR',

  -- Zahlung
  payment_method    text        NOT NULL DEFAULT 'card'
                                CHECK (payment_method IN (
                                  'card','cash','sepa','paypal','apple_pay',
                                  'google_pay','voucher','crypto','invoice','other'
                                )),
  payment_status    text        NOT NULL DEFAULT 'completed'
                                CHECK (payment_status IN (
                                  'completed','pending','refunded','partially_refunded',
                                  'failed','cancelled','voided'
                                )),
  payment_ref       text,                                       -- Stripe/PayPal Transaction-ID

  -- Rückgabe / Refund
  refund_amount     numeric(12,2) DEFAULT 0,
  refunded_at       timestamptz,
  refunded_by       uuid        REFERENCES public.users(id),
  original_tx_id    uuid        REFERENCES public.pos_transactions(id), -- bei Rückbuchungen

  notes             text,
  metadata          jsonb       NOT NULL DEFAULT '{}',          -- Plugin-spezifische Rohdaten

  transaction_at    timestamptz NOT NULL DEFAULT NOW(),          -- Zeitpunkt der Transaktion
  created_at        timestamptz NOT NULL DEFAULT NOW(),
  updated_at        timestamptz NOT NULL DEFAULT NOW()
);

-- Performance-Indexes für häufige Abfragen
CREATE INDEX idx_pos_tx_org_id         ON public.pos_transactions(org_id);
CREATE INDEX idx_pos_tx_store_id       ON public.pos_transactions(store_id);
CREATE INDEX idx_pos_tx_plugin_id      ON public.pos_transactions(plugin_id);
CREATE INDEX idx_pos_tx_source         ON public.pos_transactions(org_id, source_system);
CREATE INDEX idx_pos_tx_status         ON public.pos_transactions(org_id, payment_status);
CREATE INDEX idx_pos_tx_date           ON public.pos_transactions(org_id, transaction_at DESC);
CREATE INDEX idx_pos_tx_date_range     ON public.pos_transactions(org_id, transaction_at)
  WHERE payment_status = 'completed';
-- Für Dashboard-Aggregationen (SUM total nach Datum)
CREATE INDEX idx_pos_tx_agg            ON public.pos_transactions(org_id, transaction_at, total)
  WHERE payment_status = 'completed';

CREATE TRIGGER trg_pos_transactions_updated_at
  BEFORE UPDATE ON public.pos_transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ================================================================
-- 8. ERROR_LOGS (System-Fehler & Frontend-Exceptions)
--    SUPER_ADMIN sieht ALLE Orgs — für Creator-Dashboard Monitoring.
-- ================================================================
CREATE TABLE public.error_logs (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid        REFERENCES public.organizations(id) ON DELETE CASCADE,  -- NULL = System-Level
  user_id         uuid        REFERENCES public.users(id) ON DELETE SET NULL,

  -- Klassifizierung
  level           text        NOT NULL DEFAULT 'error'
                              CHECK (level IN ('debug','info','warning','error','critical')),
  category        text        NOT NULL DEFAULT 'ui'
                              CHECK (category IN (
                                'ui','api','auth','payment','sync','pos',
                                'automation','import','database','system','security'
                              )),
  code            text,                                          -- Interner Fehlercode, z.B. "POS_SYNC_FAILED"
  message         text        NOT NULL,
  stack_trace     text,

  -- Kontext (was hat der Nutzer gerade gemacht?)
  context         jsonb       NOT NULL DEFAULT '{}'
  -- Beispiel: {"view":"pos","action":"connect_plugin","plugin":"shopify",
  --             "browser":"Chrome 125","os":"macOS","nexus_version":"1.0.0"}
  ,
  request_url     text,
  request_method  text,
  response_status integer,

  -- Client-Info
  user_agent      text,
  ip_address      inet,
  session_id      text,

  -- Lösung
  is_resolved     boolean     NOT NULL DEFAULT false,
  resolved_at     timestamptz,
  resolved_by     uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  resolution_note text,

  -- Deduplication (gleicher Fehler mehrfach)
  fingerprint     text,                                          -- Hash von category+code+message
  occurrence_count integer    NOT NULL DEFAULT 1,
  first_seen_at   timestamptz NOT NULL DEFAULT NOW(),
  last_seen_at    timestamptz NOT NULL DEFAULT NOW(),

  created_at      timestamptz NOT NULL DEFAULT NOW()
);

-- Wichtige Indexes für SUPER_ADMIN Dashboard
CREATE INDEX idx_error_logs_org_id     ON public.error_logs(org_id);
CREATE INDEX idx_error_logs_level      ON public.error_logs(level, created_at DESC);
CREATE INDEX idx_error_logs_category   ON public.error_logs(category, created_at DESC);
CREATE INDEX idx_error_logs_unresolved ON public.error_logs(created_at DESC)
  WHERE is_resolved = false;
CREATE INDEX idx_error_logs_critical   ON public.error_logs(org_id, created_at DESC)
  WHERE level IN ('error','critical');
-- Fingerprint für Deduplication
CREATE INDEX idx_error_logs_fingerprint ON public.error_logs(fingerprint)
  WHERE fingerprint IS NOT NULL;

-- ================================================================
-- ROW LEVEL SECURITY (RLS)
-- ================================================================

-- Alle Tabellen absichern
ALTER TABLE public.organizations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.companies       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contacts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_stores      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_plugins     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.error_logs      ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------
-- HELPER-FUNKTION: aktuelle User-Rolle ermitteln
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS text AS $$
  SELECT role FROM public.users WHERE id = auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- HELPER-FUNKTION: aktuelle Org-ID ermitteln
CREATE OR REPLACE FUNCTION public.get_user_org_id()
RETURNS uuid AS $$
  SELECT org_id FROM public.users WHERE id = auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- HELPER-FUNKTION: Ist der aktuelle User SUPER_ADMIN?
CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid() AND role = 'SUPER_ADMIN'
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ----------------------------------------------------------------
-- RLS POLICIES: ORGANIZATIONS
-- ----------------------------------------------------------------
-- SUPER_ADMIN sieht alle Orgs
CREATE POLICY "super_admin_all_orgs" ON public.organizations
  FOR ALL TO authenticated
  USING (public.is_super_admin());

-- Normale User sehen nur ihre eigene Org
CREATE POLICY "user_own_org" ON public.organizations
  FOR SELECT TO authenticated
  USING (id = public.get_user_org_id());

-- ----------------------------------------------------------------
-- RLS POLICIES: USERS
-- ----------------------------------------------------------------
CREATE POLICY "super_admin_all_users" ON public.users
  FOR ALL TO authenticated
  USING (public.is_super_admin());

-- User sieht sich selbst immer
CREATE POLICY "user_see_self" ON public.users
  FOR SELECT TO authenticated
  USING (id = auth.uid());

-- User sieht alle Kollegen in seiner Org
CREATE POLICY "user_see_org_members" ON public.users
  FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id());

-- ADMIN darf User in der eigenen Org bearbeiten
CREATE POLICY "admin_manage_org_users" ON public.users
  FOR ALL TO authenticated
  USING (
    org_id = public.get_user_org_id()
    AND public.get_user_role() IN ('ADMIN')
  );

-- ----------------------------------------------------------------
-- RLS POLICIES: COMPANIES
-- ----------------------------------------------------------------
CREATE POLICY "super_admin_all_companies" ON public.companies
  FOR ALL TO authenticated
  USING (public.is_super_admin());

CREATE POLICY "org_access_companies" ON public.companies
  FOR ALL TO authenticated
  USING (org_id = public.get_user_org_id())
  WITH CHECK (org_id = public.get_user_org_id());

-- ----------------------------------------------------------------
-- RLS POLICIES: CONTACTS
-- ----------------------------------------------------------------
CREATE POLICY "super_admin_all_contacts" ON public.contacts
  FOR ALL TO authenticated
  USING (public.is_super_admin());

CREATE POLICY "org_access_contacts" ON public.contacts
  FOR ALL TO authenticated
  USING (org_id = public.get_user_org_id())
  WITH CHECK (org_id = public.get_user_org_id());

-- ----------------------------------------------------------------
-- RLS POLICIES: POS_STORES
-- ----------------------------------------------------------------
CREATE POLICY "super_admin_all_stores" ON public.pos_stores
  FOR ALL TO authenticated
  USING (public.is_super_admin());

CREATE POLICY "org_access_stores" ON public.pos_stores
  FOR ALL TO authenticated
  USING (org_id = public.get_user_org_id())
  WITH CHECK (org_id = public.get_user_org_id());

-- ----------------------------------------------------------------
-- RLS POLICIES: POS_PLUGINS
-- ----------------------------------------------------------------
CREATE POLICY "super_admin_all_plugins" ON public.pos_plugins
  FOR ALL TO authenticated
  USING (public.is_super_admin());

CREATE POLICY "org_access_plugins" ON public.pos_plugins
  FOR ALL TO authenticated
  USING (org_id = public.get_user_org_id())
  WITH CHECK (org_id = public.get_user_org_id());

-- ----------------------------------------------------------------
-- RLS POLICIES: POS_TRANSACTIONS
-- ----------------------------------------------------------------
CREATE POLICY "super_admin_all_transactions" ON public.pos_transactions
  FOR ALL TO authenticated
  USING (public.is_super_admin());

-- Standard-Mitarbeiter sehen Transaktionen der eigenen Org
CREATE POLICY "org_access_transactions" ON public.pos_transactions
  FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id());

-- Nur ADMIN und MANAGER dürfen Transaktionen schreiben
CREATE POLICY "manager_write_transactions" ON public.pos_transactions
  FOR INSERT TO authenticated
  WITH CHECK (
    org_id = public.get_user_org_id()
    AND public.get_user_role() IN ('ADMIN','MANAGER','USER')
  );

-- ----------------------------------------------------------------
-- RLS POLICIES: ERROR_LOGS
-- ----------------------------------------------------------------
-- SUPER_ADMIN sieht ALLE Fehler aller Orgs (Creator Dashboard)
CREATE POLICY "super_admin_all_errors" ON public.error_logs
  FOR ALL TO authenticated
  USING (public.is_super_admin());

-- Normale User sehen nur Fehler ihrer Org
CREATE POLICY "org_access_errors" ON public.error_logs
  FOR SELECT TO authenticated
  USING (org_id = public.get_user_org_id());

-- Jeder darf Fehler für seine Org schreiben (Frontend-Logging)
CREATE POLICY "org_insert_errors" ON public.error_logs
  FOR INSERT TO authenticated
  WITH CHECK (
    org_id = public.get_user_org_id()
    OR org_id IS NULL
  );

-- ================================================================
-- VIEWS FÜR SUPER_ADMIN CREATOR-DASHBOARD
-- ================================================================

-- Plattform-Übersicht: alle Orgs mit KPIs
CREATE OR REPLACE VIEW public.v_super_admin_overview AS
SELECT
  o.id,
  o.name,
  o.slug,
  o.plan,
  o.status,
  o.country,
  o.created_at,
  COUNT(DISTINCT u.id)              AS user_count,
  COUNT(DISTINCT c.id)              AS company_count,
  COUNT(DISTINCT co.id)             AS contact_count,
  COUNT(DISTINCT pt.id)             AS transaction_count,
  COALESCE(SUM(pt.total), 0)        AS total_revenue,
  COUNT(DISTINCT el.id) FILTER (
    WHERE el.level IN ('error','critical') AND el.is_resolved = false
  )                                 AS open_errors
FROM public.organizations o
LEFT JOIN public.users u          ON u.org_id = o.id
LEFT JOIN public.companies c      ON c.org_id = o.id AND c.deleted_at IS NULL
LEFT JOIN public.contacts co      ON co.org_id = o.id AND co.deleted_at IS NULL
LEFT JOIN public.pos_transactions pt ON pt.org_id = o.id
  AND pt.payment_status = 'completed'
LEFT JOIN public.error_logs el    ON el.org_id = o.id
WHERE o.deleted_at IS NULL
GROUP BY o.id, o.name, o.slug, o.plan, o.status, o.country, o.created_at;

-- Fehler-Dashboard für SUPER_ADMIN
CREATE OR REPLACE VIEW public.v_error_dashboard AS
SELECT
  el.*,
  o.name  AS org_name,
  o.plan  AS org_plan,
  u.email AS user_email,
  u.full_name AS user_name
FROM public.error_logs el
LEFT JOIN public.organizations o ON o.id = el.org_id
LEFT JOIN public.users u         ON u.id = el.user_id
ORDER BY el.created_at DESC;

-- ================================================================
-- SEED: SUPER_ADMIN User (nach Supabase Auth Registrierung eintragen)
-- ================================================================
-- Ausführen NACH der Supabase Auth Registrierung:
--
-- INSERT INTO public.users (id, org_id, email, full_name, role, status)
-- VALUES (
--   '<UUID aus auth.users>',    -- deine Supabase User-ID
--   NULL,                       -- SUPER_ADMIN gehört keiner Org
--   'issashaker574@gmail.com',
--   'Issa Shaker',
--   'SUPER_ADMIN',
--   'active'
-- );
--
-- ================================================================

-- ================================================================
-- AUDIT-LOG TRIGGER (optional aber empfohlen)
-- Loggt jede Änderung an kritischen Tabellen in error_logs.
-- ================================================================
CREATE OR REPLACE FUNCTION audit_critical_changes()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO public.error_logs (org_id, level, category, code, message, context)
    VALUES (
      OLD.org_id,
      'info',
      'system',
      'AUDIT_DELETE',
      TG_TABLE_NAME || ' record deleted',
      jsonb_build_object('table', TG_TABLE_NAME, 'record_id', OLD.id, 'deleted_by', auth.uid())
    );
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Audit-Trigger auf kritischen Tabellen
CREATE TRIGGER audit_companies_delete
  AFTER DELETE ON public.companies
  FOR EACH ROW EXECUTE FUNCTION audit_critical_changes();

CREATE TRIGGER audit_contacts_delete
  AFTER DELETE ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION audit_critical_changes();

CREATE TRIGGER audit_pos_transactions_delete
  AFTER DELETE ON public.pos_transactions
  FOR EACH ROW EXECUTE FUNCTION audit_critical_changes();

-- ================================================================
-- KOMMENTAR-DOKUMENTATION
-- ================================================================
COMMENT ON TABLE public.organizations   IS 'Mandanten/Workspaces. Jede Firma = 1 Org.';
COMMENT ON TABLE public.users           IS 'User-Profile, erweitert auth.users. SUPER_ADMIN hat org_id=NULL.';
COMMENT ON TABLE public.companies       IS 'CRM B2B-Firmenprofile.';
COMMENT ON TABLE public.contacts        IS 'CRM Kontakte/Leads, verknüpft mit Companies.';
COMMENT ON TABLE public.pos_stores      IS 'POS Standorte/Filialen pro Org.';
COMMENT ON TABLE public.pos_plugins     IS 'Verbundene externe POS-Systeme (Shopify, Square, etc.).';
COMMENT ON TABLE public.pos_transactions IS 'Kassenbewegungen aller Kanäle und POS-Plugins.';
COMMENT ON TABLE public.error_logs      IS 'System- und Frontend-Fehler. SUPER_ADMIN sieht alle Orgs.';

COMMENT ON COLUMN public.users.role IS
  'SUPER_ADMIN=Creator-Dashboard alle Orgs | ADMIN=Vollzugriff Org | MANAGER=Schreiben | USER=Standard | VIEWER=Lesen';
COMMENT ON COLUMN public.pos_plugins.api_key_hash IS
  'API-Key wird IMMER gehasht gespeichert (pgcrypto crypt). Niemals Plaintext!';
COMMENT ON COLUMN public.pos_transactions.items IS
  'JSONB Array: [{name,qty,unit_price,vat_rate,total}]';
COMMENT ON COLUMN public.error_logs.fingerprint IS
  'MD5-Hash aus category+code+message für Deduplication gleicher Fehler.';
