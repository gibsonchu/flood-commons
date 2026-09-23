create or replace function fc_private.review(revision uuid, decision text, reason text, expected_published uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare v fc_private.revisions; r fc_private.records; p jsonb; doc jsonb;
begin
 select * into v from fc_private.revisions where id=revision;
 select * into r from fc_private.records where id=v.record_id for update;
 if r.id is null or not fc_private.allowed(r.scope_id,array['editor','admin']) then raise exception 'editor scope access denied' using errcode='42501'; end if;
 if reason is null or length(trim(reason))=0 then raise exception 'review reason required'; end if;
 if r.published_revision is distinct from expected_published then raise exception 'publication conflict' using errcode='40001'; end if;
 if decision in ('publish','revise','exclude') and r.latest_revision<>revision then raise exception 'only latest proposal can be reviewed' using errcode='40001'; end if;
 p:=v.payload;
 if decision='publish' then
  if jsonb_array_length(p->'publication_blockers')<>0 then raise exception 'unresolved publication blockers'; end if;
  if p->>'evidence_status'='index_only' then raise exception 'full source review required'; end if;
  if p->>'publication_mode' is distinct from 'link_only' then raise exception 'hosting and embedding are disabled in this release'; end if;
  if p->>'geography_precision' not in ('named_area','citywide','regional','unknown') then raise exception 'precise location publication requires future privacy workflow'; end if;
  if p->>'collection'='help' then
   if p->>'next_review_due' is null or (p->>'next_review_due')::date<current_date or p->>'review_owner' is null then raise exception 'help requires review owner and future review date'; end if;
   if not exists(select 1 from fc_private.memberships m where m.user_id=(p->>'review_owner')::uuid and m.active and (m.scope_id=r.scope_id or m.role='admin')) then raise exception 'review owner must be an active member in scope'; end if;
   if p#>>'{details,availability}'='confirmed_available' and (p->>'provider_confirmed_at' is null or (p->>'provider_confirmed_at')::date>current_date) then raise exception 'dated provider confirmation required'; end if;
  end if;
  doc:=fc_private.public_document(p);
  insert into public.fc_catalog(id,external_id,revision_id,collection,document,published_at)
  values(r.id,r.external_id,v.id,r.collection,doc,now())
  on conflict(id) do update set revision_id=excluded.revision_id,document=excluded.document,published_at=excluded.published_at;
  update fc_private.records set published_revision=v.id where id=r.id;
 elsif decision='archive' then
  if r.published_revision is null or r.published_revision<>revision then raise exception 'only current publication can be archived'; end if;
  delete from public.fc_catalog where id=r.id;
  update fc_private.records set published_revision=null where id=r.id;
 elsif decision not in ('revise','exclude') then raise exception 'invalid review decision';
 end if;
 insert into fc_private.reviews(revision_id,decision,reason,reviewed_by) values(revision,decision,reason,fc_private.uid());
 insert into fc_private.audit_events(actor,action,target) values(fc_private.uid(),decision,revision::text);
end $$;


do $$ begin if to_regprocedure('public.rls_auto_enable()') is not null then execute 'revoke execute on function public.rls_auto_enable() from public,anon,authenticated'; end if; end $$;
create policy owner_only_schema on fc_private.standard_schemas to authenticated using(false);
create policy owner_only_enrollment on fc_private.pending_memberships to authenticated using(false);
create view public.fc_current_catalog with(security_invoker=true) as
select * from public.fc_catalog where collection<>'help' or (
 document#>>'{service,availability}' not in ('closed','historical','temporarily_unavailable')
 and ((document#>>'{service,deadline}') is null or (document#>>'{service,deadline}')::date>=current_date));
revoke all on public.fc_current_catalog from public,anon,authenticated;
grant select on public.fc_current_catalog to anon,authenticated;
