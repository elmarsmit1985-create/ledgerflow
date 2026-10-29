-- Payroll access area. Applied to the live project on 2026-10-29, before the payroll app release.
-- Employee records (coll 'emps') and pay runs (coll 'pruns') are visible only to administrators
-- and to users given the 'payroll' area: level 1 to view, level 2 to edit. The dashboard/reports
-- "can read everything" rule does NOT apply to them. Payroll editors may also post journals.
create or replace function public.can_rec(b uuid, c text, d jsonb, w boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  s int; p int; ct int; it int; bk int; ac int; ds int; rp int; pr int;
begin
  if not public.is_member(b) then return false; end if;
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
