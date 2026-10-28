-- Applied to the live project on 2026-10-28.

-- 1. Audit log: only admins may change existing audit entries (members can still add new ones)
drop policy if exists rec_update on public.records;
create policy rec_update on public.records for update to authenticated
  using (public.can_rec(business_id, coll, data, true) and (coll <> 'audit' or public.is_admin(business_id)))
  with check (public.can_rec(business_id, coll, data, true) and (coll <> 'audit' or public.is_admin(business_id)));

-- 2. Remove table permissions the app never uses
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- 3. Fixed search_path on the record-stamping trigger function
alter function public.touch_record() set search_path = '';

-- 4. Internal event-trigger helper should not be callable through the API
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
