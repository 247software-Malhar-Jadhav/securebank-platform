-- =============================================================================
-- SecureBank — Postgres bootstrap (runs ONCE on first container init).
--
-- Database-per-service model (MICROSERVICES_SPEC §1):
--   * auth-service          -> database `auth`,       login role `auth`
--   * account-service       -> database `securebank`, schema `accounts`
--   * transaction-service   -> database `securebank`, schema `ledger`
--   * notification-service  -> database `securebank`, schema `notifications`
--
-- NOTE on the "4 databases" wording in the platform spec: the SERVICES (the source
-- of truth for what actually has to connect) put auth in its own physical database
-- `auth`, and the other three in physical database `securebank` as separate SCHEMAS.
-- We honour that here. The SCHEMAS themselves (accounts/ledger/notifications) are NOT
-- created here — each service's Flyway owns and creates its own schema
-- (`create-schemas: true`), so no service can reach into another's tables.
--
-- This script runs as the bootstrap superuser (POSTGRES_USER). It is idempotent on a
-- fresh volume; to re-run it, remove the `postgres-data` volume.
-- =============================================================================

-- ---- Login roles ------------------------------------------------------------
-- Distinct roles so each service has its own credentials (least privilege). The
-- passwords match the compose env defaults; override both in production.
CREATE ROLE auth        WITH LOGIN PASSWORD 'auth';
CREATE ROLE securebank  WITH LOGIN PASSWORD 'securebank';

-- ---- Databases --------------------------------------------------------------
CREATE DATABASE auth        OWNER auth;
CREATE DATABASE securebank  OWNER securebank;

-- Allow the shared-DB services to create their own schemas via Flyway.
GRANT ALL PRIVILEGES ON DATABASE auth        TO auth;
GRANT ALL PRIVILEGES ON DATABASE securebank  TO securebank;

-- Make `securebank` the default-privilege owner inside its database so Flyway's
-- create-schemas works without superuser.
\connect securebank
ALTER SCHEMA public OWNER TO securebank;
GRANT ALL ON SCHEMA public TO securebank;
