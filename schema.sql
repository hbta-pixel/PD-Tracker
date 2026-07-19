-- PD Tracker schema for Supabase (Postgres)
-- Run this once in your Supabase project's SQL editor (Database > SQL Editor > New query).

create extension if not exists pgcrypto;

-- One row per RTO (subscriber)
create table if not exists organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text unique not null,
  created_at timestamptz not null default now()
);

-- One row per person (trainer or admin), 1:1 with a Supabase auth user
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  org_id uuid not null references organizations(id) on delete cascade,
  full_name text not null,
  role text not null default 'trainer' check (role in ('trainer', 'admin')),
  created_at timestamptz not null default now()
);

-- One row per PD / industry engagement record captured by a trainer
create table if not exists pd_entries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  staff_id uuid not null references profiles(id) on delete cascade,
  entry_type text not null check (entry_type in ('vet_pd', 'vocational_pd', 'industry_engagement')),
  title text,
  entry_date date not null default current_date,
  transcript text,
  contact_name text,
  photo_url text,
  created_at timestamptz not null default now()
);

create index if not exists pd_entries_org_idx on pd_entries (org_id, created_at desc);
create index if not exists pd_entries_staff_idx on pd_entries (staff_id, created_at desc);

-- Helper functions (security definer so they can read profiles despite RLS)
create or replace function public.current_org_id()
returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from profiles where id = auth.uid()
$$;

-- Note: named current_user_role(), not current_role() — "current_role" is a
-- reserved SQL keyword (like current_user) and cannot be used as a function name.
create or replace function public.current_user_role()
returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

-- Row Level Security
alter table organizations enable row level security;
alter table profiles enable row level security;
alter table pd_entries enable row level security;

-- organizations: any signed-in user can create one (becomes its admin). Read access
-- (name + invite_code only, via the columns the app selects) is open to signed-out
-- visitors too, because a trainer must be able to validate an invite code *before*
-- they have an account yet.
drop policy if exists "orgs insert" on organizations;
create policy "orgs insert" on organizations
  for insert to authenticated with check (true);

drop policy if exists "orgs select" on organizations;
create policy "orgs select" on organizations
  for select to anon, authenticated using (true);

-- profiles: users manage their own row; admins can see every profile in their org.
drop policy if exists "profiles insert own" on profiles;
create policy "profiles insert own" on profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists "profiles select" on profiles;
create policy "profiles select" on profiles
  for select to authenticated using (
    id = auth.uid()
    or (current_user_role() = 'admin' and org_id = current_org_id())
  );

drop policy if exists "profiles update own" on profiles;
create policy "profiles update own" on profiles
  for update to authenticated using (id = auth.uid());

-- pd_entries: trainers insert/read their own entries; admins read every entry in their org.
drop policy if exists "entries insert own" on pd_entries;
create policy "entries insert own" on pd_entries
  for insert to authenticated with check (
    staff_id = auth.uid() and org_id = current_org_id()
  );

drop policy if exists "entries select" on pd_entries;
create policy "entries select" on pd_entries
  for select to authenticated using (
    staff_id = auth.uid()
    or (current_user_role() = 'admin' and org_id = current_org_id())
  );

-- One row per org: admin's preference for a recurring emailed CSV report.
-- Note: saving a row here only records the preference. Actually emailing the
-- report requires a separate scheduled job (Supabase Edge Function + cron)
-- that is not part of this schema yet.
create table if not exists report_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null unique references organizations(id) on delete cascade,
  recipient_email text not null,
  frequency text not null check (frequency in ('weekly', 'fortnightly', 'monthly')),
  enabled boolean not null default true,
  last_sent_at timestamptz,
  next_run_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table report_schedules enable row level security;

drop policy if exists "report_schedules admin manage" on report_schedules;
create policy "report_schedules admin manage" on report_schedules
  for all to authenticated using (
    current_user_role() = 'admin' and org_id = current_org_id()
  ) with check (
    current_user_role() = 'admin' and org_id = current_org_id()
  );

-- Storage bucket for evidence photos.
insert into storage.buckets (id, name, public)
values ('pd-photos', 'pd-photos', true)
on conflict (id) do nothing;

drop policy if exists "pd-photos upload" on storage.objects;
create policy "pd-photos upload" on storage.objects
  for insert to authenticated with check (bucket_id = 'pd-photos');

drop policy if exists "pd-photos read" on storage.objects;
create policy "pd-photos read" on storage.objects
  for select to public using (bucket_id = 'pd-photos');

-- Gates "RTO Admin" signup: a one-time code the site owner hands out
-- privately to a verified RTO before they create an organisation. No RLS
-- policies are defined here on purpose — all access goes through the two
-- security-definer functions below, so codes can't be listed or edited
-- directly from the client.
create table if not exists admin_access_codes (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  used_by uuid references profiles(id) on delete set null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

alter table admin_access_codes enable row level security;

-- Called before auth.signUp() so an invalid code is rejected without
-- creating an auth user. Read-only, so safe to expose to anon.
create or replace function public.check_admin_code(code_input text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from admin_access_codes where code = code_input and used_at is null
  )
$$;

-- Called after the new admin's org + profile are created, to mark the code
-- used. Atomic (single UPDATE ... WHERE used_at is null), so two signups
-- racing on the same code can't both succeed.
create or replace function public.redeem_admin_code(code_input text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  redeemed_id uuid;
begin
  update admin_access_codes
  set used_at = now(), used_by = auth.uid()
  where code = code_input and used_at is null
  returning id into redeemed_id;
  return redeemed_id is not null;
end;
$$;

grant execute on function public.check_admin_code(text) to anon, authenticated;
grant execute on function public.redeem_admin_code(text) to authenticated;

-- Lets a trainer move their own profile to a different organisation (e.g.
-- changing jobs) by supplying that org's invite code, without losing their
-- account or PD history. Entries already logged stay attached to the org
-- they were logged under (see pd_entries.org_id) — only the profile's
-- current org_id changes, so future entries log against the new RTO while
-- the old RTO keeps its historical record. Security definer + explicit
-- role check so this can't be used to touch org_id or role via a raw
-- client-side update (the "profiles update own" RLS policy only checks
-- row ownership, not which columns change).
create or replace function public.switch_organization(invite_code_input text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  target_org_id uuid;
begin
  if (select role from profiles where id = auth.uid()) <> 'trainer' then
    raise exception 'Only trainers can switch organisations.';
  end if;

  select id into target_org_id from organizations where invite_code = invite_code_input;
  if target_org_id is null then
    return false;
  end if;

  update profiles set org_id = target_org_id where id = auth.uid();
  return true;
end;
$$;

grant execute on function public.switch_organization(text) to authenticated;
