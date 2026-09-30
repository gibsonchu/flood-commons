-- 008: entry points for the Flood Commons Workspace.
--
--  * fc_workspace_records: every record in the caller's scope with its latest
--    standard document, status, and audience.
--  * fc_save_record / fc_import_records: save standard documents with a target
--    status in one step, refusing to overwrite someone else's newer save.
--  * fc_set_record_status: publish, draft, hide, trash, restore.
--  * People: list members, add a colleague by email, change roles.
--  * Activity: who did what, newest first.
--  * The pilot research drafts are marked retired so they stay out of the
--    Workspace (still kept in history).

alter table fc_private.records add column retired boolean not null default false;
update fc_private.records set retired = true where status = 'excluded' and created_at < '2026-09-29';

create view public.fc_workspace_records with (security_invoker = true) as
 select r.id, r.external_id, r.collection, r.status, r.audience, r.latest_revision, r.published_revision,
  (r.published_revision is not null and r.published_revision <> r.latest_revision) as has_unpublished_changes,
  v.payload->'standard_record' as document, v.created_at as updated_at, r.created_at
 from fc_private.records r join fc_private.revisions v on v.id = r.latest_revision
 where not r.retired;
revoke all on public.fc_workspace_records from public, anon, authenticated;
grant select on public.fc_workspace_records to authenticated;

create function fc_private.my_scope() returns uuid language sql stable security definer set search_path='' as $$
 select scope_id from fc_private.memberships where user_id = fc_private.uid() and active
$$;

-- ---------------------------------------------------------------- status
create function fc_private.set_record_status(record uuid, target text, reason text default null) returns text language plpgsql security definer set search_path='' as $$
declare r fc_private.records; why text := coalesce(nullif(trim(reason), ''), 'Changed in the Workspace');
begin
 select * into r from fc_private.records where id = record for update;
 if r.id is null or r.retired or not fc_private.allowed(r.scope_id, array['editor','admin']) then raise exception 'Only editors can change whether a record is public' using errcode = '42501'; end if;
 if target = 'published' then
  perform fc_private.review(r.latest_revision, 'publish', why, r.published_revision);
 elsif target in ('draft', 'hidden', 'trash') then
  if r.published_revision is not null then perform fc_private.review(r.published_revision, 'archive', why, r.published_revision); end if;
  if target = 'trash' then perform fc_private.review(r.latest_revision, 'exclude', why, null);
  else perform fc_private.set_unpublished_status(record, target); end if;
 elsif target = 'restore' then
  if r.status <> 'excluded' then raise exception 'Only records in the trash can be restored'; end if;
  perform fc_private.set_unpublished_status(record, 'draft');
 else raise exception 'Unknown status %', target;
 end if;
 return (select status from fc_private.records where id = record);
end $$;

-- ---------------------------------------------------------------- save
-- expected_revision: the revision the editor started from (null for a new
-- record). A newer save by someone else is never overwritten.
create function fc_private.save_record(doc jsonb, target text default 'draft', record_audience text default null, expected_revision uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare rid uuid; r fc_private.records; scope uuid; rev uuid; final text;
begin
 if doc->>'id' !~ '^urn:uuid:[0-9a-f-]{36}$' then raise exception 'The record needs a urn:uuid id'; end if;
 rid := substr(doc->>'id', 10)::uuid;
 if target not in ('published', 'draft', 'hidden') then raise exception 'Status must be published, draft, or hidden'; end if;
 select * into r from fc_private.records where id = rid for update;
 if r.id is not null then
  if r.retired then raise exception 'This record is retired'; end if;
  if r.latest_revision is distinct from expected_revision then
   raise exception 'Someone else saved “%” after you opened it. Reload to see their changes, then try again.', doc->>'title' using errcode = '40001';
  end if;
  if r.status = 'excluded' then raise exception '“%” is in the trash. Restore it first.', doc->>'title'; end if;
 elsif expected_revision is not null then
  raise exception 'This record no longer exists' using errcode = '40001';
 end if;
 scope := coalesce(r.scope_id, fc_private.my_scope());
 if scope is null then raise exception 'Your account is not an active Flood Commons member' using errcode = '42501'; end if;
 rev := fc_private.propose_standard(doc, scope, coalesce(record_audience, r.audience, 'public'), fc_private.uid());
 -- Contributors can save drafts; only editors change what's public.
 if target = 'draft' and r.published_revision is null and coalesce(r.status, 'draft') = 'draft' then
  final := 'draft';
 else
  final := fc_private.set_record_status(rid, target, 'Saved in the Workspace');
 end if;
 return jsonb_build_object('id', rid, 'revision', rev, 'status', final);
end $$;

-- All-or-nothing: if any item fails, nothing is saved.
create function fc_private.import_records_standard(items jsonb, filename text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; n integer := 0;
begin
 if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then raise exception 'Nothing to import'; end if;
 if jsonb_array_length(items) > 2000 then raise exception 'Up to 2,000 rows per upload'; end if;
 for item in select value from jsonb_array_elements(items) loop
  begin
   perform fc_private.save_record(item->'doc', coalesce(item->>'status', 'published'), item->>'audience', nullif(item->>'expected_revision', '')::uuid);
  exception when others then
   raise exception 'Line %: %', coalesce(item->>'line', '?'), sqlerrm using errcode = sqlstate;
  end;
  n := n + 1;
 end loop;
 insert into fc_private.audit_events(actor, action, target) values (fc_private.uid(), 'import_csv', coalesce(filename, 'upload') || ': ' || n || ' rows');
 return jsonb_build_object('count', n);
end $$;

-- ---------------------------------------------------------------- people
create function fc_private.members() returns table(user_id uuid, email text, role text, active boolean, pending boolean) language plpgsql stable security definer set search_path='' as $$
begin
 if not fc_private.is_admin() then raise exception 'Only admins can manage people' using errcode = '42501'; end if;
 return query
  select m.user_id, u.email::text, m.role, m.active, false from fc_private.memberships m join auth.users u on u.id = m.user_id
  union all
  select null::uuid, p.email, p.role, true, true from fc_private.pending_memberships p
  order by 2;
end $$;

-- Add a colleague. If they already have a confirmed account they're added now;
-- otherwise they're added the first time they sign in with that email.
create function fc_private.add_member(email_address text, member_role text) returns text language plpgsql security definer set search_path='' as $$
declare e text := lower(trim(email_address)); uid uuid; scope uuid := fc_private.my_scope();
begin
 if not fc_private.is_admin() then raise exception 'Only admins can manage people' using errcode = '42501'; end if;
 if e !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'That does not look like an email address'; end if;
 if member_role not in ('contributor', 'editor', 'admin') then raise exception 'Role must be contributor, editor, or admin'; end if;
 select id into uid from auth.users where lower(email) = e and email_confirmed_at is not null;
 if uid is not null then
  if exists (select 1 from fc_private.memberships where user_id = uid) then raise exception '% is already a member', e; end if;
  insert into fc_private.memberships(user_id, scope_id, role) values (uid, scope, member_role);
 else
  insert into fc_private.pending_memberships(email, scope_id, role) values (e, scope, member_role)
  on conflict (email) do update set role = excluded.role, scope_id = excluded.scope_id;
 end if;
 insert into fc_private.audit_events(actor, action, target) values (fc_private.uid(), 'add_member', e);
 return case when uid is null then 'pending' else 'active' end;
end $$;

create function fc_private.remove_pending_member(email_address text) returns void language plpgsql security definer set search_path='' as $$
begin
 if not fc_private.is_admin() then raise exception 'Only admins can manage people' using errcode = '42501'; end if;
 delete from fc_private.pending_memberships where email = lower(trim(email_address));
 insert into fc_private.audit_events(actor, action, target) values (fc_private.uid(), 'remove_pending_member', lower(trim(email_address)));
end $$;

-- ---------------------------------------------------------------- activity
create function fc_private.activity(max_rows integer default 200) returns table(at timestamptz, who text, action text, target text, title text) language plpgsql stable security definer set search_path='' as $$
begin
 if not fc_private.is_member() then raise exception 'Members only' using errcode = '42501'; end if;
 return query
  select a.created_at, coalesce(u.email::text, 'system'), a.action, a.target,
   coalesce(v.payload->>'title', lv.payload->>'title', s.place_name)
  from fc_private.audit_events a
  left join auth.users u on u.id = a.actor
  cross join lateral (select case when a.target ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then a.target::uuid end as tid) t
  left join fc_private.revisions v on v.id = t.tid
  left join fc_private.records r on r.id = t.tid
  left join fc_private.revisions lv on lv.id = r.latest_revision
  left join fc_private.clip_submissions s on s.id = t.tid
  where not coalesce(r.retired, false)
   and not exists (select 1 from fc_private.records rr where rr.id = v.record_id and rr.retired)
  order by a.id desc
  limit least(max_rows, 1000);
end $$;

-- ---------------------------------------------------------------- public wrappers
create function public.fc_save_record(doc jsonb, target text default 'draft', record_audience text default null, expected_revision uuid default null)
 returns jsonb language sql security invoker set search_path='' as $$ select fc_private.save_record(doc, target, record_audience, expected_revision); $$;
create function public.fc_import_records(items jsonb, filename text default null)
 returns jsonb language sql security invoker set search_path='' as $$ select fc_private.import_records_standard(items, filename); $$;
create function public.fc_set_record_status(record uuid, target text, reason text default null)
 returns text language sql security invoker set search_path='' as $$ select fc_private.set_record_status(record, target, reason); $$;
create function public.fc_set_audience(record uuid, new_audience text)
 returns void language sql security invoker set search_path='' as $$ select fc_private.set_audience(record, new_audience); $$;
create function public.fc_members()
 returns table(user_id uuid, email text, role text, active boolean, pending boolean) language sql security invoker set search_path='' as $$ select * from fc_private.members(); $$;
create function public.fc_add_member(email_address text, member_role text)
 returns text language sql security invoker set search_path='' as $$ select fc_private.add_member(email_address, member_role); $$;
create function public.fc_update_member(member uuid, member_role text, enabled boolean)
 returns void language sql security invoker set search_path='' as $$ select fc_private.set_member(member, member_role, enabled); $$;
create function public.fc_remove_pending_member(email_address text)
 returns void language sql security invoker set search_path='' as $$ select fc_private.remove_pending_member(email_address); $$;
create function public.fc_activity(max_rows integer default 200)
 returns table(at timestamptz, who text, action text, target text, title text) language sql security invoker set search_path='' as $$ select * from fc_private.activity(max_rows); $$;

revoke all on function fc_private.my_scope(), fc_private.set_record_status(uuid,text,text), fc_private.save_record(jsonb,text,text,uuid),
 fc_private.import_records_standard(jsonb,text), fc_private.members(), fc_private.add_member(text,text), fc_private.remove_pending_member(text), fc_private.activity(integer),
 public.fc_save_record(jsonb,text,text,uuid), public.fc_import_records(jsonb,text), public.fc_set_record_status(uuid,text,text), public.fc_set_audience(uuid,text),
 public.fc_members(), public.fc_add_member(text,text), public.fc_update_member(uuid,text,boolean), public.fc_remove_pending_member(text), public.fc_activity(integer)
 from public, anon, authenticated;
grant execute on function fc_private.my_scope(), fc_private.set_record_status(uuid,text,text), fc_private.save_record(jsonb,text,text,uuid),
 fc_private.import_records_standard(jsonb,text), fc_private.members(), fc_private.add_member(text,text), fc_private.remove_pending_member(text), fc_private.activity(integer),
 public.fc_save_record(jsonb,text,text,uuid), public.fc_import_records(jsonb,text), public.fc_set_record_status(uuid,text,text), public.fc_set_audience(uuid,text),
 public.fc_members(), public.fc_add_member(text,text), public.fc_update_member(uuid,text,boolean), public.fc_remove_pending_member(text), public.fc_activity(integer)
 to authenticated;
