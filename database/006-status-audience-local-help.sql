-- 006: record status and audience, honest verification, and a loader for
-- standard Flood Commons documents. Prepares the hosted catalog to be the
-- single source for Local Help (public) and the Blue Dots AI (internal).
--
--  * status   draft | published | hidden | excluded   (editorial state)
--  * audience public | internal                         (who may read a published record)
--    Anonymous readers only ever see published + public records.
--  * Publication keeps each record's own verification status instead of
--    stamping every published record "reviewed".
--  * The temporary research drafts from the pilot are excluded (not deleted).

-- ---------------------------------------------------------------- status & audience
alter table fc_private.records
  add column status text not null default 'draft' check (status in ('draft','published','hidden','excluded')),
  add column audience text not null default 'internal' check (audience in ('public','internal'));
update fc_private.records set status = 'published' where published_revision is not null;
create index on fc_private.records(status);

-- Status follows review decisions. Rejecting a proposed change to a live
-- record leaves it published; excluding an unpublished record excludes it.
create function fc_private.track_review_status() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update fc_private.records r set status = case new.decision
   when 'publish' then 'published'
   when 'archive' then 'hidden'
   when 'exclude' then case when r.published_revision is not null then 'published' else 'excluded' end
   else case when r.published_revision is not null then 'published' when r.status = 'hidden' then 'hidden' else 'draft' end
 end
 from fc_private.revisions v where v.id = new.revision_id and r.id = v.record_id;
 return new;
end $$;
create trigger track_review_status after insert on fc_private.reviews for each row execute function fc_private.track_review_status();

-- A new proposal brings an excluded record back as a draft.
create function fc_private.track_proposal_status() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update fc_private.records set status = 'draft' where id = new.record_id and status = 'excluded';
 return new;
end $$;
create trigger track_proposal_status after insert on fc_private.revisions for each row execute function fc_private.track_proposal_status();

-- Editors choose how an unpublished record is labelled.
create function fc_private.set_unpublished_status(record uuid, new_status text) returns void language plpgsql security definer set search_path='' as $$
declare r fc_private.records;
begin
 select * into r from fc_private.records where id = record for update;
 if r.id is null or not fc_private.allowed(r.scope_id, array['editor','admin']) then raise exception 'editor scope access denied' using errcode='42501'; end if;
 if new_status not in ('draft','hidden') then raise exception 'status must be draft or hidden'; end if;
 if r.published_revision is not null then raise exception 'archive the publication first'; end if;
 update fc_private.records set status = new_status where id = r.id;
 insert into fc_private.audit_events(actor,action,target) values(fc_private.uid(),'status:'||new_status,r.id::text);
end $$;

-- The public catalog carries the audience; it follows the record.
alter table public.fc_catalog add column audience text not null default 'internal' check (audience in ('public','internal'));
create index on public.fc_catalog(audience);
create function fc_private.catalog_audience() returns trigger language plpgsql security definer set search_path='' as $$
begin
 select audience into new.audience from fc_private.records where id = new.id;
 return new;
end $$;
create trigger catalog_audience before insert or update on public.fc_catalog for each row execute function fc_private.catalog_audience();

create function fc_private.set_audience(record uuid, new_audience text) returns void language plpgsql security definer set search_path='' as $$
declare r fc_private.records;
begin
 select * into r from fc_private.records where id = record for update;
 if r.id is null or not fc_private.allowed(r.scope_id, array['editor','admin']) then raise exception 'editor scope access denied' using errcode='42501'; end if;
 if new_audience not in ('public','internal') then raise exception 'audience must be public or internal'; end if;
 update fc_private.records set audience = new_audience where id = r.id;
 update public.fc_catalog set audience = new_audience where id = r.id;
 insert into fc_private.audit_events(actor,action,target) values(fc_private.uid(),'audience:'||new_audience,r.id::text);
end $$;

create function fc_private.is_member() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from fc_private.memberships where user_id = fc_private.uid() and active)
$$;

-- Anonymous readers: published + public only. Members also see internal records.
drop policy catalog_read on public.fc_catalog;
create policy catalog_public_read on public.fc_catalog for select to anon using (audience = 'public');
create policy catalog_member_read on public.fc_catalog for select to authenticated using (audience = 'public' or fc_private.is_member());
-- A link is visible only when the reader can see both ends.
drop policy published_links on public.fc_relationships;
create policy visible_links on public.fc_relationships for select to anon, authenticated using (
 exists(select 1 from public.fc_catalog c where c.id = source_id) and exists(select 1 from public.fc_catalog c where c.id = target_id));

-- ---------------------------------------------------------------- honest verification
-- Publication no longer overrides verification; reviewers set it on the record.
create or replace function fc_private.public_document(p jsonb) returns jsonb language plpgsql stable set search_path='' as $$
begin
 return (p->'standard_record') || jsonb_build_object('relationships','[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- standard-document loader
-- Build the editorial envelope that propose() and the consistency triggers
-- expect from a standard FRS / FSS / FMS document, so tools can submit the
-- standard format directly.
create function fc_private.envelope(doc jsonb, review_owner uuid default null) returns jsonb language plpgsql stable set search_path='' as $$
declare collection text := case doc->>'standard' when 'FSS' then 'help' when 'FRS' then 'source' when 'FMS' then 'media' end;
 details jsonb := '{}'; k text;
begin
 if collection is null then raise exception 'unknown standard %', doc->>'standard'; end if;
 if doc->>'id' !~ '^urn:uuid:' then raise exception 'id must be a urn:uuid'; end if;
 if collection = 'help' then
  foreach k in array array['service_area','eligibility','availability','contact_url','phone','email','cost','hours','deadline','accessibility'] loop
   details := details || jsonb_build_object(k, coalesce(doc#>array['service',k], 'null'::jsonb));
  end loop;
 elsif collection = 'media' then
  foreach k in array array['creator','capture_date','capture_date_text','duration_seconds','evidence_kind'] loop
   details := details || jsonb_build_object(k, coalesce(doc#>array['media',k], 'null'::jsonb));
  end loop;
 elsif doc#>>'{resource,evidence_kind}' is not null then
  details := jsonb_build_object('evidence_kind', doc#>'{resource,evidence_kind}');
 end if;
 return jsonb_build_object(
  'id', doc->>'local_id',
  'uuid', substr(doc->>'id', 10),
  'collection', collection,
  'title', doc->>'title',
  'summary', doc->>'summary',
  'source_url', doc#>>'{source,url}',
  'organization', doc#>>'{source,organization}',
  'topics', coalesce(doc->'categories', '[]'::jsonb),
  'action_stages', coalesce(doc->'action_stages', '[]'::jsonb),
  'audiences', coalesce(doc->'audiences', '[]'::jsonb),
  'languages', coalesce(doc->'languages', '[]'::jsonb),
  'evidence_status', doc#>>'{source,evidence_status}',
  'rights_status', doc#>>'{rights,status}',
  'source_checked_at', doc#>>'{source,checked_at}',
  'provider_confirmed_at', doc#>>'{service,provider_confirmed_at}',
  'next_review_due', doc#>>'{service,review_due}',
  'review_owner', review_owner,
  'publication_mode', 'link_only',
  'geography_precision', 'named_area',
  'publication_blockers', '[]'::jsonb,
  'details', details,
  'standard_record', doc);
end $$;

-- Submit a standard document as a new proposal (creating the record if new).
-- Returns the new revision id. Scope and role checks happen in propose().
create function fc_private.propose_standard(doc jsonb, scope uuid, record_audience text default null, review_owner uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid := substr(doc->>'id', 10)::uuid; prior uuid; result uuid;
begin
 select latest_revision into prior from fc_private.records where id = rid;
 result := fc_private.propose(fc_private.envelope(doc, review_owner), scope, prior);
 if record_audience is not null then
  if record_audience not in ('public','internal') then raise exception 'audience must be public or internal'; end if;
  update fc_private.records set audience = record_audience where id = rid;
 end if;
 return result;
end $$;

revoke all on function fc_private.track_review_status(), fc_private.track_proposal_status(), fc_private.catalog_audience(),
 fc_private.set_unpublished_status(uuid,text), fc_private.set_audience(uuid,text), fc_private.is_member(),
 fc_private.envelope(jsonb,uuid), fc_private.propose_standard(jsonb,uuid,text,uuid) from public, anon, authenticated;
grant execute on function fc_private.is_member(), fc_private.set_unpublished_status(uuid,text), fc_private.set_audience(uuid,text),
 fc_private.envelope(jsonb,uuid), fc_private.propose_standard(jsonb,uuid,text,uuid) to authenticated;

-- ---------------------------------------------------------------- retire the pilot drafts
-- The pilot's temporary research drafts are excluded, not deleted: they stay in
-- history but out of every catalog, feed, and search.
insert into fc_private.reviews(revision_id, decision, reason, reviewed_by)
select r.latest_revision, 'exclude', 'Temporary pilot research set; not part of the catalog.', '00000000-0000-0000-0000-000000000000'
from fc_private.records r
where r.published_revision is null and r.latest_revision is not null and r.created_at < '2026-09-29';
insert into fc_private.audit_events(actor, action, target)
values (null, 'exclude_pilot_drafts', (select count(*) from fc_private.records where status = 'excluded')::text);
