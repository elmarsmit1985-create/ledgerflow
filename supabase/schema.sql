-- LedgerFlow / LedgerX: Supabase database setup
-- Project: ledgerflow (jhqlqcnvceuxtzgxxlel), region eu-west-1
-- Snapshot of the live database as of 2026-10-28, including the
-- security hardening in migrations/20261028_security_hardening.sql.
-- Running this file on an empty Supabase project recreates the setup.

-- ---------- Tables ----------
create table if not exists public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  name text not null default '',
  role text not null default 'user' check (role in ('admin','user')),
  perm jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  primary key (business_id, user_id)
);

create table if not exists public.invites (
  business_id uuid not null references public.businesses(id) on delete cascade,
  email text not null,
  name text not null default '',
  role text not null default 'user' check (role in ('admin','user')),
  perm jsonb not null default '{}'::jsonb,
  primary key (business_id, email)
);

-- All app data lives here as one JSON document per record.
-- coll = collection (contacts, docs, jr, pays, bank, items, accts, audit, biz, seq, ...)
create table if not exists public.records (
  business_id uuid not null references public.businesses(id) on delete cascade,
  coll text not null,
  id text not null,
  data jsonb not null,
  rev integer not null default 1,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (business_id, coll, id)
);
create index if not exists records_changed_idx on public.records (business_id, updated_at);

alter table public.businesses enable row level security;
alter table public.members    enable row level security;
alter table public.invites    enable row level security;
alter table public.records    enable row level security;

-- ---------- Helper functions ----------
create or replace function public.is_member(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where business_id = b and user_id = auth.uid())
$$;

create or replace function public.is_admin(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where business_id = b and user_id = auth.uid() and role = 'admin')
$$;

-- Access level for an area: 0 none, 1 view, 2 edit. Admins always 2.
create or replace function public.area_level(b uuid, a text) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when role = 'admin' then 2 else coalesce((perm ->> a)::int, 0) end
    from public.members where business_id = b and user_id = auth.uid()
  ), 0)
$$;

-- Can the current user read (w=false) or write (w=true) a record of collection c?
create or replace function public.can_rec(b uuid, c text, d jsonb, w boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  s int; p int; ct int; it int; bk int; ac int; ds int; rp int;
begin
  if not public.is_member(b) then return false; end if;
  if public.is_admin(b) then return true; end if;
  if c = 'audit' then return w; end if;
  if c = 'biz' then return not w; end if;
  s := public.area_level(b,'sales');      p := public.area_level(b,'purchases');
  ct := public.area_level(b,'contacts');  it := public.area_level(b,'items');
  bk := public.area_level(b,'banking');   ac := public.area_level(b,'accounting');
  ds := public.area_level(b,'dash');      rp := public.area_level(b,'reports');
  if greatest(s,p,ct,it,bk,ac,ds,rp) = 0 then return false; end if;
  if not w then
    if greatest(ds,rp) >= 1 then return true; end if;
    return case c
      when 'contacts' then greatest(ct,s,p) >= 1
      when 'items'    then greatest(it,s,p) >= 1
      when 'bank'     then bk >= 1
      when 'rules'    then bk >= 1
      when 'docs'     then (case when left(coalesce(d->>'kind',''),1)='s' then s else p end) >= 1
      when 'accts'    then true
      when 'jr'       then true
      else greatest(s,p) >= 1
    end;
  end if;
  return case c
    when 'contacts' then ct >= 2
    when 'items'    then greatest(it,s,p) >= 2
    when 'bank'     then bk >= 2
    when 'rules'    then bk >= 2
    when 'docs'     then (case when left(coalesce(d->>'kind',''),1)='s' then s else p end) >= 2
    when 'accts'    then ac >= 2
    when 'jr'       then greatest(s,p,bk,ac) >= 2
    else greatest(s,p) >= 2
  end;
end
$$;

-- Turn pending invites for the signed-in user's email into memberships.
create or replace function public.claim_invites() returns void
language plpgsql security definer set search_path = public as $$
declare
  em text := lower(auth.jwt() ->> 'email');
begin
  if auth.uid() is null or em is null then return; end if;
  insert into public.members (business_id, user_id, email, name, role, perm)
    select business_id, auth.uid(), em, name, role, perm from public.invites where lower(email) = em
    on conflict (business_id, user_id) do nothing;
  delete from public.invites where lower(email) = em;
end
$$;

-- Create a business and make the caller its administrator.
create or replace function public.create_business(n text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  b uuid;
  em text := lower(auth.jwt() ->> 'email');
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  insert into public.businesses (name) values (coalesce(nullif(trim(n), ''), 'My business')) returning id into b;
  insert into public.members (business_id, user_id, email, name, role)
    values (b, auth.uid(), em, coalesce(auth.jwt() -> 'user_metadata' ->> 'name', ''), 'admin');
  return b;
end
$$;

-- Stamp who changed a record and when.
create or replace function public.touch_record() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end
$$;

drop trigger if exists records_touch on public.records;
create trigger records_touch before insert or update on public.records
  for each row execute function public.touch_record();

-- ---------- Policies ----------
drop policy if exists biz_select on public.businesses;
create policy biz_select on public.businesses for select to authenticated using (public.is_member(id));
drop policy if exists biz_update on public.businesses;
create policy biz_update on public.businesses for update to authenticated
  using (public.is_admin(id)) with check (public.is_admin(id));

drop policy if exists mem_select on public.members;
create policy mem_select on public.members for select to authenticated
  using (user_id = auth.uid() or public.is_admin(business_id));
drop policy if exists mem_update on public.members;
create policy mem_update on public.members for update to authenticated
  using (public.is_admin(business_id)) with check (public.is_admin(business_id));
drop policy if exists mem_delete on public.members;
create policy mem_delete on public.members for delete to authenticated using (public.is_admin(business_id));

drop policy if exists inv_all on public.invites;
create policy inv_all on public.invites for all to authenticated
  using (public.is_admin(business_id)) with check (public.is_admin(business_id));

drop policy if exists rec_select on public.records;
create policy rec_select on public.records for select to authenticated
  using (public.can_rec(business_id, coll, data, false));
drop policy if exists rec_insert on public.records;
create policy rec_insert on public.records for insert to authenticated
  with check (public.can_rec(business_id, coll, data, true));
-- Audit entries can be added by members but only changed by admins.
drop policy if exists rec_update on public.records;
create policy rec_update on public.records for update to authenticated
  using (public.can_rec(business_id, coll, data, true) and (coll <> 'audit' or public.is_admin(business_id)))
  with check (public.can_rec(business_id, coll, data, true) and (coll <> 'audit' or public.is_admin(business_id)));

-- ---------- Grants ----------
-- Only what the app uses. Records are never hard-deleted (soft delete via "deleted").
revoke all on public.businesses, public.members, public.invites, public.records from anon, authenticated;
grant select, update on public.businesses to authenticated;
grant select, update, delete on public.members to authenticated;
grant select, insert, update, delete on public.invites to authenticated;
grant select, insert, update on public.records to authenticated;
