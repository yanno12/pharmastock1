-- OPTIONAL. Only for running the project on PLAIN PostgreSQL (e.g. CI) instead of Supabase.
-- It fakes the small part of Supabase that PharmaStock depends on:
-- the anon / authenticated roles, the auth.users table, and auth.uid().
-- Run it BEFORE the migrations, as a superuser. Do NOT run it on Supabase.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;

create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text);

-- Same contract as Supabase: the caller's id comes from the JWT claim setting.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
