-- Runs once, on the OLTP database's first boot.

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- smolquery's Postgres wire listener as a foreign server. The password is
-- the API key. sslmode 'disable' because the listener runs without TLS in
-- this kind-only example; use 'require' or 'verify-full' anywhere else.
CREATE SERVER smol FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'smolquery', port '5432', dbname 'smolquery', sslmode 'disable');

CREATE USER MAPPING FOR app SERVER smol
  OPTIONS (user 'smolquery', password 'kind-only-api-key');

-- The OLTP table a smolquery dataset will be joined with: twenty users,
-- every fourth on the pro plan.
CREATE TABLE public.users (
  id    bigint PRIMARY KEY,
  email text NOT NULL,
  plan  text NOT NULL
);

INSERT INTO public.users (id, email, plan)
SELECT i,
       'user' || i || '@example.com',
       CASE WHEN i % 4 = 0 THEN 'pro' ELSE 'free' END
FROM generate_series(1, 20) AS i;
