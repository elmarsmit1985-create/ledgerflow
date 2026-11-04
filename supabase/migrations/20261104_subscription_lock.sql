-- Kontivo: 14-day free trial and subscription lock.
-- A business can use the app while it is in its trial or has a paid period running.
-- After that it is locked: its members cannot read or change any records,
-- user profiles or invites. Only their own membership row and the lock status stay readable.

alter table public.businesses
  add column if not exists trial_ends timestamptz not null default (now() + interval '14 days'),
  add column if not exists paid_until timestamptz,
  add column if not exists always_on boolean not null default false;

-- always_on: never locks (Kontivo's own business, ECS Africa). Set by Kontivo only.

-- Existing businesses get a fresh 14-day trial from today so nobody is locked out by this change.
update public.businesses set trial_ends = greatest(trial_ends, now() + interval '14 days');

-- Users may only rename their business. Trial and payment dates are set by Kontivo only.
revoke update on public.businesses from authenticated;
grant update (name) on public.businesses to authenticated;

-- Is the business inside its trial or a paid period?
create or replace function public.biz_active(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select always_on or now() < greatest(trial_ends, coalesce(paid_until, '-infinity'::timestamptz))
                   from public.businesses where id = b), false)
$$;

-- Lock status for the signed-in user's business(es). Readable even when locked.
create or replace function public.my_access()
returns table (business_id uuid, name text, role text, trial_ends timestamptz, paid_until timestamptz, active boolean, status text)
language sql stable security definer set search_path = public as $$
  select b.id, b.name, m.role, b.trial_ends, b.paid_until, public.biz_active(b.id),
         case when b.always_on then 'always_on'
              when b.paid_until is not null and now() < b.paid_until then 'paid'
              when now() < b.trial_ends then 'trial'
              when b.paid_until is not null then 'unpaid'
              else 'trial_over' end
  from public.members m join public.businesses b on b.id = m.business_id
  where m.user_id = auth.uid()
  order by m.created_at
$$;

-- Records: nothing can be read or written while the business is locked.
create or replace function public.can_rec(b uuid, c text, d jsonb, w boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  s int; p int; ct int; it int; bk int; ac int; ds int; rp int; pr int;
begin
  if not public.is_member(b) then return false; end if;
  if not public.biz_active(b) then return false; end if;
  if public.is_admin(b) then return true; end if;
  pr := public.area_level(b,'payroll');
  if c in ('emps','pruns') then return pr >= (case when w then 2 else 1 end); end if;
  if c = 'audit' then return w; end if;
  if c = 'biz' then return not w; end if;
  s := public.area_level(b,'sales');      p := public.area_level(b,'purchases');
  ct := public.area_level(b,'contacts');  it := public.area_level(b,'items');
  bk := public.area_level(b,'banking');   ac := public.area_level(b,'accounting');
  ds := public.area_level(b,'dash');      rp := public.area_level(b,'reports');
  if greatest(s,p,ct,it,bk,ac,ds,rp,pr) = 0 then return false; end if;
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
    when 'jr'       then greatest(s,p,bk,ac,pr) >= 2
    else greatest(s,p) >= 2
  end;
end
$$;

-- User profiles and invites: hidden and frozen while locked (own membership row stays readable).
drop policy if exists mem_select on public.members;
create policy mem_select on public.members for select to authenticated
  using (user_id = auth.uid() or (public.is_admin(business_id) and public.biz_active(business_id)));
drop policy if exists mem_update on public.members;
create policy mem_update on public.members for update to authenticated
  using (public.is_admin(business_id) and public.biz_active(business_id))
  with check (public.is_admin(business_id) and public.biz_active(business_id));
drop policy if exists mem_delete on public.members;
create policy mem_delete on public.members for delete to authenticated
  using (public.is_admin(business_id) and public.biz_active(business_id));

drop policy if exists inv_all on public.invites;
create policy inv_all on public.invites for all to authenticated
  using (public.is_admin(business_id) and public.biz_active(business_id))
  with check (public.is_admin(business_id) and public.biz_active(business_id));

-- Kontivo sets the paid period when a payment comes in (service role only, e.g. a payment webhook).
create or replace function public.set_paid_until(b uuid, until timestamptz) returns void
language sql security definer set search_path = public as $$
  update public.businesses set paid_until = until where id = b
$$;

revoke execute on function public.set_paid_until(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.biz_active(uuid) from public, anon;
revoke execute on function public.my_access() from public, anon;
grant execute on function public.biz_active(uuid) to authenticated;
grant execute on function public.my_access() to authenticated;
