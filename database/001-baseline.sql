-- Declarative baseline for a NEW database. Applied transactionally by bootstrap.
-- Never expose fc_private through Supabase Data API.
create schema fc_private;

revoke all on schema fc_private from public;
grant usage on schema fc_private to authenticated;

alter default privileges in schema fc_private revoke execute on functions from public;

create table fc_private.scopes(id uuid primary key default gen_random_uuid(), name text not null);
create table fc_private.memberships(
 user_id uuid primary key, scope_id uuid not null references fc_private.scopes,
 role text not null check(role in ('contributor','editor','admin')), active boolean not null default true
);
create index on fc_private.memberships(scope_id);
create function fc_private.uid() returns uuid language sql stable set search_path='' as $$
 select auth.uid()
$$;
create function fc_private.allowed(s uuid, roles text[] default array['contributor','editor','admin'])
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from fc_private.memberships m where m.user_id=fc_private.uid()
 and m.active and m.role=any(roles) and (m.scope_id=s or m.role='admin'))
$$;
create function fc_private.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from fc_private.memberships where user_id=fc_private.uid() and active and role='admin')
$$;
create table fc_private.invitations(
 id uuid primary key default gen_random_uuid(), email text not null, scope_id uuid not null references fc_private.scopes,
 role text not null check(role in ('contributor','editor')), expires_at timestamptz not null,
 created_by uuid not null, accepted_by uuid, accepted_at timestamptz, revoked boolean not null default false
);
create index on fc_private.invitations(scope_id);
create table fc_private.terms(id text primary key, dimension text not null, label text not null, definition text not null, aliases jsonb not null default '[]');
create table fc_private.places(id text primary key, payload jsonb not null);
create table fc_private.events(id text primary key, payload jsonb not null);
create table fc_private.import_batches(
 id uuid primary key default gen_random_uuid(), scope_id uuid not null references fc_private.scopes,
 checksum text not null, filename text not null, created_by uuid not null,
 created_at timestamptz not null default now(), unique(scope_id,checksum)
);
create table fc_private.records(
 id uuid primary key, external_id text not null unique, scope_id uuid not null references fc_private.scopes,
 collection text not null check(collection in ('source','media','help')), source_url text not null,
 latest_revision uuid, published_revision uuid, created_by uuid not null,
 created_at timestamptz not null default now()
);
create index on fc_private.records(scope_id);
create index on fc_private.records(source_url);
create table fc_private.revisions(
 id uuid primary key default gen_random_uuid(), record_id uuid not null references fc_private.records,
 parent_revision uuid references fc_private.revisions, payload jsonb not null,
 created_by uuid not null, created_at timestamptz not null default now(),
 batch_id uuid references fc_private.import_batches, unique(record_id,id)
);
create index on fc_private.revisions(parent_revision);
create index on fc_private.revisions(batch_id);
alter table fc_private.records add foreign key(id,latest_revision) references fc_private.revisions(record_id,id) deferrable initially deferred;
alter table fc_private.records add foreign key(id,published_revision) references fc_private.revisions(record_id,id) deferrable initially deferred;
create index on fc_private.records(latest_revision);
create index on fc_private.records(published_revision);
create table fc_private.revision_terms(
 revision_id uuid references fc_private.revisions, term_id text references fc_private.terms,
 primary key(revision_id,term_id)
);
create index on fc_private.revision_terms(term_id);
create table fc_private.revision_places(
 revision_id uuid references fc_private.revisions, place_id text references fc_private.places,
 relation text not null check(relation in ('covers','depicts','serves')), primary key(revision_id,place_id)
);
create index on fc_private.revision_places(place_id);
create table fc_private.revision_events(
 revision_id uuid primary key references fc_private.revisions, event_id text not null references fc_private.events
);
create index on fc_private.revision_events(event_id);
create table fc_private.relationships(
 revision_id uuid references fc_private.revisions, target_id uuid references fc_private.records,
 relation text not null, primary key(revision_id,target_id,relation)
);
create index on fc_private.relationships(target_id);
create table fc_private.reviews(
 id uuid primary key default gen_random_uuid(), revision_id uuid not null references fc_private.revisions,
 decision text not null check(decision in ('publish','revise','exclude','archive')), reason text not null check(length(trim(reason))>0),
 reviewed_by uuid not null, reviewed_at timestamptz not null default now()
);
create index on fc_private.reviews(revision_id);
create table fc_private.audit_events(
 id bigint generated always as identity primary key, actor uuid, action text not null,
 target text not null, created_at timestamptz not null default now()
);
create table public.fc_catalog(
 id uuid primary key, external_id text not null unique, revision_id uuid not null,
 collection text not null, document jsonb not null, published_at timestamptz not null,
 search_vector tsvector generated always as (to_tsvector('english',(document->>'title')||' '||(document->>'summary')||' '||coalesce(document->>'geography',''))) stored
);
create index on public.fc_catalog using gin(search_vector);
create index on public.fc_catalog using gin(document jsonb_path_ops);
create index on public.fc_catalog(collection,external_id);
alter table public.fc_catalog enable row level security;
revoke all on public.fc_catalog from public,anon,authenticated;
grant select on public.fc_catalog to anon,authenticated;
create policy catalog_read on public.fc_catalog for select to anon,authenticated using(true);

-- Revision content and audit history are append-only even for application administrators.
create function fc_private.immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'immutable history' using errcode='42501'; end $$;
create trigger immutable_revision before update or delete on fc_private.revisions for each row execute function fc_private.immutable();
create trigger immutable_review before update or delete on fc_private.reviews for each row execute function fc_private.immutable();
create trigger immutable_audit before update or delete on fc_private.audit_events for each row execute function fc_private.immutable();

create function fc_private.invite(email_address text, scope uuid, invited_role text)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not fc_private.is_admin() then raise exception 'administrator required' using errcode='42501'; end if;
 if email_address !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'invalid email'; end if;
 insert into fc_private.invitations(email,scope_id,role,expires_at,created_by)
 values(lower(email_address),scope,invited_role,now()+interval '7 days',fc_private.uid()) returning id into result;
 insert into fc_private.audit_events(actor,action,target) values(fc_private.uid(),'invite',result::text);
 return result;
end $$;
create function fc_private.accept_invite(invitation_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare inv fc_private.invitations; claims jsonb:=nullif(current_setting('request.jwt.claims',true),'')::jsonb;
begin
 if fc_private.uid() is null or claims->>'email_verified' is distinct from 'true' then raise exception 'verified account required' using errcode='42501'; end if;
 select * into inv from fc_private.invitations where id=invitation_id for update;
 if inv.id is null or inv.revoked or inv.accepted_at is not null or inv.expires_at<=now() or inv.email is distinct from lower(claims->>'email') then
 raise exception 'invitation unavailable' using errcode='42501'; end if;
 -- Existing memberships cannot be elevated or moved through invitation acceptance.
 insert into fc_private.memberships(user_id,scope_id,role) values(fc_private.uid(),inv.scope_id,inv.role);
 update fc_private.invitations set accepted_by=fc_private.uid(),accepted_at=now() where id=inv.id;
 insert into fc_private.audit_events(actor,action,target) values(fc_private.uid(),'accept_invite',inv.id::text);
end $$;
create function fc_private.set_member(member_id uuid, member_role text, enabled boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not fc_private.is_admin() then raise exception 'administrator required' using errcode='42501'; end if;
 if member_id=fc_private.uid() then raise exception 'cannot change own administrative membership'; end if;
 update fc_private.memberships set role=member_role,active=enabled where user_id=member_id;
 if not found then raise exception 'member not found'; end if;
 insert into fc_private.audit_events(actor,action,target) values(fc_private.uid(),'set_member',member_id::text);
end $$;

create function fc_private.propose(p jsonb, scope uuid, expected_revision uuid default null, batch uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare r fc_private.records; new_id uuid; dimension text; field text; term text; place text; link jsonb; target uuid;
begin
 if not fc_private.allowed(scope) then raise exception 'scope access denied' using errcode='42501'; end if;
 if jsonb_typeof(p) is distinct from 'object' or length(trim(coalesce(p->>'title','')))=0 or length(trim(coalesce(p->>'summary','')))=0
 or p->>'collection' not in ('source','media','help') or p->>'source_url' !~ '^https?://' or p->>'id' is null or p->>'uuid' is null
 or jsonb_typeof(p->'publication_blockers') is distinct from 'array' then raise exception 'invalid record'; end if;
 if batch is not null and not exists(select 1 from fc_private.import_batches b where b.id=batch and b.scope_id=scope) then raise exception 'invalid batch'; end if;
 select * into r from fc_private.records where id=(p->>'uuid')::uuid for update;
 if r.id is null then
  if expected_revision is not null then raise exception 'revision conflict' using errcode='40001'; end if;
  insert into fc_private.records(id,external_id,scope_id,collection,source_url,created_by)
  values((p->>'uuid')::uuid,p->>'id',scope,p->>'collection',p->>'source_url',fc_private.uid()) returning * into r;
 else
  if r.scope_id<>scope or not fc_private.allowed(r.scope_id) then raise exception 'scope access denied' using errcode='42501'; end if;
  if r.latest_revision is distinct from expected_revision then raise exception 'revision conflict' using errcode='40001'; end if;
  if r.external_id<>p->>'id' or r.collection<>p->>'collection' then raise exception 'immutable record identity'; end if;
 end if;
 -- A proposal can never nominate itself as published, regardless of imported status.
 p:=p||jsonb_build_object('review_status','draft','editor_decision','pending');
 insert into fc_private.revisions(record_id,parent_revision,payload,created_by,batch_id)
 values(r.id,r.latest_revision,p,fc_private.uid(),batch) returning id into new_id;
 for field,dimension in select * from (values('topics','topic'),('flood_mechanisms','mechanism'),('action_stages','stage'),('audiences','audience')) as dims(f,d) loop
  for term in select jsonb_array_elements_text(coalesce(p->field,'[]')) loop
   insert into fc_private.revision_terms values(new_id,dimension||':'||term);
  end loop;
 end loop;
 if p#>>'{details,availability}' is not null then insert into fc_private.revision_terms values(new_id,'availability:'||(p#>>'{details,availability}')); end if;
 if p#>>'{details,evidence_kind}' is not null then insert into fc_private.revision_terms values(new_id,'evidence_kind:'||(p#>>'{details,evidence_kind}')); end if;
 for place in select jsonb_array_elements_text(coalesce(p->'place_ids','[]')) loop
  insert into fc_private.revision_places values(new_id,place,case r.collection when 'help' then 'serves' when 'media' then 'depicts' else 'covers' end);
 end loop;
 if p->>'event_id' is not null then insert into fc_private.revision_events values(new_id,p->>'event_id'); end if;
 for link in select value from jsonb_array_elements(coalesce(p->'related_records','[]')) loop
  select id into target from fc_private.records where external_id=link->>'record_id';
  if target is null then raise exception 'unknown related record'; end if;
  insert into fc_private.relationships values(new_id,target,link->>'relation');
 end loop;
 update fc_private.records set latest_revision=new_id where id=r.id;
 insert into fc_private.audit_events(actor,action,target) values(fc_private.uid(),'propose',new_id::text);
 return new_id;
end $$;

-- Deliberate allowlist; never copy complete payload or arbitrary nested details to the public table.
create function fc_private.public_document(p jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb:='{}'; detail jsonb:='{}'; k text;
begin
 foreach k in array array['id','uuid','collection','subtype','title','summary','source_url','organization','geography','geography_precision','flood_mechanisms','topics','action_stages','audiences','languages','event_id','place_ids','publication_date','publication_date_text','source_checked_at','provider_confirmed_at','rights_status','license_name','license_url','publication_mode','next_review_due'] loop
  result:=result||jsonb_build_object(k,p->k);
 end loop;
 foreach k in array case p->>'collection'
 when 'help' then array['service_area','eligibility','availability','contact_url','phone','email','cost','hours','deadline','accessibility','service_languages','service_location']
 when 'media' then array['original_title','creator','capture_date','capture_date_text','duration_seconds','source_credit','evidence_kind']
 else array['evidence_kind','temporal_coverage','spatial_coverage','version','scenario','methodology_url'] end loop
  if p->'details' ? k then detail:=detail||jsonb_build_object(k,p#>array['details',k]); end if;
 end loop;
 return result||jsonb_build_object('details',detail,'review_status','published');
end $$;

create function fc_private.review(revision uuid, decision text, reason text, expected_published uuid default null)
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
  doc:=fc_private.public_document(p)||jsonb_build_object('published_at',now());
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

create function fc_private.create_batch(scope uuid, sha text, filename text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not fc_private.allowed(scope,array['editor','admin']) then raise exception 'editor required' using errcode='42501'; end if;
 insert into fc_private.import_batches(scope_id,checksum,filename,created_by) values(scope,sha,filename,fc_private.uid()) returning id into result;
 return result;
end $$;
create function fc_private.import_records(items jsonb, scope uuid, sha text, filename text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare batch uuid; item jsonb; prior uuid; n integer:=0;
begin
 if not fc_private.allowed(scope,array['editor','admin']) then raise exception 'editor required' using errcode='42501'; end if;
 -- Serialize imports per scope; duplicate checks and revision pointers remain atomic.
 perform 1 from fc_private.scopes where id=scope for update;
 select id into batch from fc_private.import_batches where scope_id=scope and checksum=sha;
 if batch is not null then return jsonb_build_object('batch_id',batch,'duplicate',true,'count',0); end if;
 batch:=fc_private.create_batch(scope,sha,filename);
 -- Reserve all identities before resolving forward/cyclic relationships.
 for item in select value from jsonb_array_elements(items) loop
  insert into fc_private.records(id,external_id,scope_id,collection,source_url,created_by)
  values((item->>'uuid')::uuid,item->>'id',scope,item->>'collection',item->>'source_url',fc_private.uid()) on conflict(id) do nothing;
 end loop;
 for item in select value from jsonb_array_elements(items) loop
  select latest_revision into prior from fc_private.records where id=(item->>'uuid')::uuid;
  perform fc_private.propose(item,scope,prior,batch); n:=n+1;
 end loop;
 return jsonb_build_object('batch_id',batch,'duplicate',false,'count',n);
end $$;

alter table fc_private.scopes enable row level security;
revoke all on fc_private.scopes from public,anon,authenticated;
grant select on fc_private.scopes to authenticated;
create policy scoped_read on fc_private.scopes for select to authenticated using (fc_private.allowed(id));

alter table fc_private.memberships enable row level security;
revoke all on fc_private.memberships from public,anon,authenticated;
grant select on fc_private.memberships to authenticated;
create policy scoped_read on fc_private.memberships for select to authenticated using (user_id=fc_private.uid() or fc_private.is_admin());

alter table fc_private.invitations enable row level security;
revoke all on fc_private.invitations from public,anon,authenticated;
grant select on fc_private.invitations to authenticated;
create policy scoped_read on fc_private.invitations for select to authenticated using (fc_private.is_admin());

alter table fc_private.terms enable row level security;
revoke all on fc_private.terms from public,anon,authenticated;
grant select on fc_private.terms to authenticated;
create policy scoped_read on fc_private.terms for select to authenticated using (exists(select 1 from fc_private.memberships where user_id=fc_private.uid() and active));

alter table fc_private.places enable row level security;
revoke all on fc_private.places from public,anon,authenticated;
grant select on fc_private.places to authenticated;
create policy scoped_read on fc_private.places for select to authenticated using (exists(select 1 from fc_private.memberships where user_id=fc_private.uid() and active));

alter table fc_private.events enable row level security;
revoke all on fc_private.events from public,anon,authenticated;
grant select on fc_private.events to authenticated;
create policy scoped_read on fc_private.events for select to authenticated using (exists(select 1 from fc_private.memberships where user_id=fc_private.uid() and active));

alter table fc_private.import_batches enable row level security;
revoke all on fc_private.import_batches from public,anon,authenticated;
grant select on fc_private.import_batches to authenticated;
create policy scoped_read on fc_private.import_batches for select to authenticated using (fc_private.allowed(scope_id));

alter table fc_private.records enable row level security;
revoke all on fc_private.records from public,anon,authenticated;
grant select on fc_private.records to authenticated;
create policy scoped_read on fc_private.records for select to authenticated using (fc_private.allowed(scope_id));

alter table fc_private.revisions enable row level security;
revoke all on fc_private.revisions from public,anon,authenticated;
grant select on fc_private.revisions to authenticated;
create policy scoped_read on fc_private.revisions for select to authenticated using (exists(select 1 from fc_private.records r where r.id=record_id and fc_private.allowed(r.scope_id)));

alter table fc_private.audit_events enable row level security;
revoke all on fc_private.audit_events from public,anon,authenticated;
grant select on fc_private.audit_events to authenticated;
create policy scoped_read on fc_private.audit_events for select to authenticated using (fc_private.is_admin());

alter table fc_private.revision_terms enable row level security;
revoke all on fc_private.revision_terms from public,anon,authenticated;
grant select on fc_private.revision_terms to authenticated;
create policy scoped_read on fc_private.revision_terms for select to authenticated using (exists(select 1 from fc_private.revisions v join fc_private.records r on r.id=v.record_id where v.id=revision_id and fc_private.allowed(r.scope_id)));

alter table fc_private.revision_places enable row level security;
revoke all on fc_private.revision_places from public,anon,authenticated;
grant select on fc_private.revision_places to authenticated;
create policy scoped_read on fc_private.revision_places for select to authenticated using (exists(select 1 from fc_private.revisions v join fc_private.records r on r.id=v.record_id where v.id=revision_id and fc_private.allowed(r.scope_id)));

alter table fc_private.revision_events enable row level security;
revoke all on fc_private.revision_events from public,anon,authenticated;
grant select on fc_private.revision_events to authenticated;
create policy scoped_read on fc_private.revision_events for select to authenticated using (exists(select 1 from fc_private.revisions v join fc_private.records r on r.id=v.record_id where v.id=revision_id and fc_private.allowed(r.scope_id)));

alter table fc_private.relationships enable row level security;
revoke all on fc_private.relationships from public,anon,authenticated;
grant select on fc_private.relationships to authenticated;
create policy scoped_read on fc_private.relationships for select to authenticated using (exists(select 1 from fc_private.revisions v join fc_private.records r on r.id=v.record_id where v.id=revision_id and fc_private.allowed(r.scope_id)));

alter table fc_private.reviews enable row level security;
revoke all on fc_private.reviews from public,anon,authenticated;
grant select on fc_private.reviews to authenticated;
create policy scoped_read on fc_private.reviews for select to authenticated using (exists(select 1 from fc_private.revisions v join fc_private.records r on r.id=v.record_id where v.id=revision_id and fc_private.allowed(r.scope_id)));
revoke all on all functions in schema fc_private from public,anon,authenticated;
grant execute on function fc_private.uid() to authenticated;
grant execute on function fc_private.allowed(uuid,text[]) to authenticated;
grant execute on function fc_private.is_admin() to authenticated;
grant execute on function fc_private.invite(text,uuid,text) to authenticated;
grant execute on function fc_private.accept_invite(uuid) to authenticated;
grant execute on function fc_private.set_member(uuid,text,boolean) to authenticated;
grant execute on function fc_private.propose(jsonb,uuid,uuid,uuid) to authenticated;
grant execute on function fc_private.review(uuid,text,text,uuid) to authenticated;
grant execute on function fc_private.import_records(jsonb,uuid,text,text) to authenticated;

-- Draft interoperable schemas, validated on every revision insertion.
create extension if not exists pg_jsonschema with schema extensions;
create table fc_private.standard_schemas(standard text primary key, version text not null, schema_document jsonb not null);
alter table fc_private.standard_schemas enable row level security;
revoke all on fc_private.standard_schemas from public,anon,authenticated;
insert into fc_private.standard_schemas values('FRS','0.1.0','{"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": "https://github.com/gibsonchu/flood-commons/raw/main/standards/frs.schema.json", "title": "FRS 0.1.0 \u2014 Draft", "type": "object", "properties": {"id": {"type": "string", "format": "uri", "pattern": "^urn:uuid:[0-9a-f-]{36}$", "description": "Globally portable record identity. Preserve across publishers and revisions."}, "local_id": {"type": "string", "description": "Publisher-local identifier, retained when migrating the pilot."}, "standard": {"const": "FRS"}, "schema_version": {"const": "0.1.0"}, "publisher": {"type": "object", "properties": {"id": {"type": "string", "format": "uri"}, "name": {"type": "string"}}, "required": ["id", "name"], "additionalProperties": false}, "title": {"type": "string", "minLength": 1}, "summary": {"type": "string", "minLength": 1}, "categories": {"type": "array", "items": {"type": "string", "description": "Controlled taxonomy term key."}, "uniqueItems": true}, "tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "action_stages": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "audiences": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "languages": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "places": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "relation": {"enum": ["covers", "depicts", "serves", "observed_at"]}, "precision": {"enum": ["named_area", "exact", "approximate", "unknown"]}, "geometry": {"oneOf": [{"type": "null"}, {"type": "object", "properties": {"type": {"const": "Point"}, "coordinates": {"type": "array", "prefixItems": [{"type": "number", "minimum": -180, "maximum": 180}, {"type": "number", "minimum": -90, "maximum": 90}], "minItems": 2, "maxItems": 2}}, "required": ["type", "coordinates"], "additionalProperties": false}]}}, "required": ["id", "name", "relation", "precision", "geometry"], "additionalProperties": false}, "uniqueItems": true}, "event": {"oneOf": [{"type": "null"}, {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "date_text": {"type": "string", "description": "Qualified date text, not an invented exact timestamp."}}, "required": ["id", "name", "date_text"], "additionalProperties": false}]}, "source": {"type": "object", "properties": {"url": {"type": "string", "format": "uri"}, "organization": {"type": "string"}, "checked_at": {"type": ["string", "null"], "format": "date"}, "evidence_status": {"enum": ["website_documented", "index_only", "provider_confirmed", "unknown"]}}, "required": ["url", "organization", "checked_at", "evidence_status"], "additionalProperties": false}, "rights": {"type": "object", "properties": {"status": {"enum": ["not_assessed", "license_reported", "needs_review", "cleared"]}, "license": {"type": ["string", "null"]}, "license_url": {"type": ["string", "null"], "format": "uri"}, "attribution": {"type": ["string", "null"]}}, "required": ["status", "license", "license_url", "attribution"], "additionalProperties": false}, "verification": {"type": "object", "properties": {"status": {"enum": ["unreviewed", "source_checked", "reviewed", "disputed"]}, "method": {"type": ["string", "null"]}, "verified_at": {"type": ["string", "null"], "format": "date"}}, "required": ["status", "method", "verified_at"], "additionalProperties": false}, "relationships": {"type": "array", "items": {"type": "object", "properties": {"target_id": {"type": "string", "format": "uri"}, "relation": {"type": "string", "description": "Typed association; shared event does not establish causation."}}, "required": ["target_id", "relation"], "additionalProperties": false}, "uniqueItems": true}, "metadata": {"type": "object", "properties": {"created_at": {"type": "string", "format": "date-time"}, "updated_at": {"type": "string", "format": "date-time"}, "record_version": {"type": "integer", "minimum": 1}}, "required": ["created_at", "updated_at", "record_version"], "additionalProperties": false}, "resource": {"type": "object", "properties": {"type": {"type": "string"}, "publication_date": {"type": ["string", "null"], "format": "date"}, "publication_date_text": {"type": ["string", "null"]}, "evidence_kind": {"enum": [null, "modeled", "instrument_observation", "impact_analysis", "instructional"]}, "document_url": {"type": "string", "format": "uri"}}, "required": ["type", "publication_date", "publication_date_text", "evidence_kind", "document_url"], "additionalProperties": false}}, "required": ["id", "local_id", "standard", "schema_version", "publisher", "title", "summary", "categories", "tags", "action_stages", "audiences", "languages", "places", "event", "source", "rights", "verification", "relationships", "metadata", "resource"], "additionalProperties": false}'::jsonb);
insert into fc_private.standard_schemas values('FMS','0.1.0','{"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": "https://github.com/gibsonchu/flood-commons/raw/main/standards/fms.schema.json", "title": "FMS 0.1.0 \u2014 Draft", "type": "object", "properties": {"id": {"type": "string", "format": "uri", "pattern": "^urn:uuid:[0-9a-f-]{36}$", "description": "Globally portable record identity. Preserve across publishers and revisions."}, "local_id": {"type": "string", "description": "Publisher-local identifier, retained when migrating the pilot."}, "standard": {"const": "FMS"}, "schema_version": {"const": "0.1.0"}, "publisher": {"type": "object", "properties": {"id": {"type": "string", "format": "uri"}, "name": {"type": "string"}}, "required": ["id", "name"], "additionalProperties": false}, "title": {"type": "string", "minLength": 1}, "summary": {"type": "string", "minLength": 1}, "categories": {"type": "array", "items": {"type": "string", "description": "Controlled taxonomy term key."}, "uniqueItems": true}, "tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "action_stages": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "audiences": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "languages": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "places": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "relation": {"enum": ["covers", "depicts", "serves", "observed_at"]}, "precision": {"enum": ["named_area", "exact", "approximate", "unknown"]}, "geometry": {"oneOf": [{"type": "null"}, {"type": "object", "properties": {"type": {"const": "Point"}, "coordinates": {"type": "array", "prefixItems": [{"type": "number", "minimum": -180, "maximum": 180}, {"type": "number", "minimum": -90, "maximum": 90}], "minItems": 2, "maxItems": 2}}, "required": ["type", "coordinates"], "additionalProperties": false}]}}, "required": ["id", "name", "relation", "precision", "geometry"], "additionalProperties": false}, "uniqueItems": true}, "event": {"oneOf": [{"type": "null"}, {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "date_text": {"type": "string", "description": "Qualified date text, not an invented exact timestamp."}}, "required": ["id", "name", "date_text"], "additionalProperties": false}]}, "source": {"type": "object", "properties": {"url": {"type": "string", "format": "uri"}, "organization": {"type": "string"}, "checked_at": {"type": ["string", "null"], "format": "date"}, "evidence_status": {"enum": ["website_documented", "index_only", "provider_confirmed", "unknown"]}}, "required": ["url", "organization", "checked_at", "evidence_status"], "additionalProperties": false}, "rights": {"type": "object", "properties": {"status": {"enum": ["not_assessed", "license_reported", "needs_review", "cleared"]}, "license": {"type": ["string", "null"]}, "license_url": {"type": ["string", "null"], "format": "uri"}, "attribution": {"type": ["string", "null"]}}, "required": ["status", "license", "license_url", "attribution"], "additionalProperties": false}, "verification": {"type": "object", "properties": {"status": {"enum": ["unreviewed", "source_checked", "reviewed", "disputed"]}, "method": {"type": ["string", "null"]}, "verified_at": {"type": ["string", "null"], "format": "date"}}, "required": ["status", "method", "verified_at"], "additionalProperties": false}, "relationships": {"type": "array", "items": {"type": "object", "properties": {"target_id": {"type": "string", "format": "uri"}, "relation": {"type": "string", "description": "Typed association; shared event does not establish causation."}}, "required": ["target_id", "relation"], "additionalProperties": false}, "uniqueItems": true}, "metadata": {"type": "object", "properties": {"created_at": {"type": "string", "format": "date-time"}, "updated_at": {"type": "string", "format": "date-time"}, "record_version": {"type": "integer", "minimum": 1}}, "required": ["created_at", "updated_at", "record_version"], "additionalProperties": false}, "media": {"type": "object", "properties": {"type": {"enum": ["photograph", "map_image", "video", "animation", "observation"]}, "creator": {"type": ["string", "null"]}, "capture_date": {"type": ["string", "null"], "format": "date"}, "capture_date_text": {"type": ["string", "null"]}, "asset_url": {"type": ["string", "null"], "format": "uri"}, "alt_text": {"type": ["string", "null"]}, "duration_seconds": {"type": ["number", "null"], "exclusiveMinimum": 0}, "evidence_kind": {"type": ["string", "null"]}, "observation": {"oneOf": [{"type": "null"}, {"type": "object", "properties": {"observed_at": {"type": ["string", "null"], "format": "date-time"}, "description": {"type": "string"}, "flood_depth_cm": {"type": ["number", "null"], "minimum": 0}, "damage_classification": {"enum": ["none_reported", "property", "infrastructure", "mixed", "unknown"]}}, "required": ["observed_at", "description", "flood_depth_cm", "damage_classification"], "additionalProperties": false}]}}, "required": ["type", "creator", "capture_date", "capture_date_text", "asset_url", "alt_text", "duration_seconds", "evidence_kind", "observation"], "additionalProperties": false}}, "required": ["id", "local_id", "standard", "schema_version", "publisher", "title", "summary", "categories", "tags", "action_stages", "audiences", "languages", "places", "event", "source", "rights", "verification", "relationships", "metadata", "media"], "additionalProperties": false, "allOf": [{"if": {"properties": {"media": {"properties": {"type": {"const": "observation"}}}}}, "then": {"properties": {"media": {"properties": {"observation": {"type": "object"}}}}}}]}'::jsonb);
insert into fc_private.standard_schemas values('FSS','0.1.0','{"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": "https://github.com/gibsonchu/flood-commons/raw/main/standards/fss.schema.json", "title": "FSS 0.1.0 \u2014 Draft", "type": "object", "properties": {"id": {"type": "string", "format": "uri", "pattern": "^urn:uuid:[0-9a-f-]{36}$", "description": "Globally portable record identity. Preserve across publishers and revisions."}, "local_id": {"type": "string", "description": "Publisher-local identifier, retained when migrating the pilot."}, "standard": {"const": "FSS"}, "schema_version": {"const": "0.1.0"}, "publisher": {"type": "object", "properties": {"id": {"type": "string", "format": "uri"}, "name": {"type": "string"}}, "required": ["id", "name"], "additionalProperties": false}, "title": {"type": "string", "minLength": 1}, "summary": {"type": "string", "minLength": 1}, "categories": {"type": "array", "items": {"type": "string", "description": "Controlled taxonomy term key."}, "uniqueItems": true}, "tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "action_stages": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "audiences": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "languages": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "places": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "relation": {"enum": ["covers", "depicts", "serves", "observed_at"]}, "precision": {"enum": ["named_area", "exact", "approximate", "unknown"]}, "geometry": {"oneOf": [{"type": "null"}, {"type": "object", "properties": {"type": {"const": "Point"}, "coordinates": {"type": "array", "prefixItems": [{"type": "number", "minimum": -180, "maximum": 180}, {"type": "number", "minimum": -90, "maximum": 90}], "minItems": 2, "maxItems": 2}}, "required": ["type", "coordinates"], "additionalProperties": false}]}}, "required": ["id", "name", "relation", "precision", "geometry"], "additionalProperties": false}, "uniqueItems": true}, "event": {"oneOf": [{"type": "null"}, {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "date_text": {"type": "string", "description": "Qualified date text, not an invented exact timestamp."}}, "required": ["id", "name", "date_text"], "additionalProperties": false}]}, "source": {"type": "object", "properties": {"url": {"type": "string", "format": "uri"}, "organization": {"type": "string"}, "checked_at": {"type": ["string", "null"], "format": "date"}, "evidence_status": {"enum": ["website_documented", "index_only", "provider_confirmed", "unknown"]}}, "required": ["url", "organization", "checked_at", "evidence_status"], "additionalProperties": false}, "rights": {"type": "object", "properties": {"status": {"enum": ["not_assessed", "license_reported", "needs_review", "cleared"]}, "license": {"type": ["string", "null"]}, "license_url": {"type": ["string", "null"], "format": "uri"}, "attribution": {"type": ["string", "null"]}}, "required": ["status", "license", "license_url", "attribution"], "additionalProperties": false}, "verification": {"type": "object", "properties": {"status": {"enum": ["unreviewed", "source_checked", "reviewed", "disputed"]}, "method": {"type": ["string", "null"]}, "verified_at": {"type": ["string", "null"], "format": "date"}}, "required": ["status", "method", "verified_at"], "additionalProperties": false}, "relationships": {"type": "array", "items": {"type": "object", "properties": {"target_id": {"type": "string", "format": "uri"}, "relation": {"type": "string", "description": "Typed association; shared event does not establish causation."}}, "required": ["target_id", "relation"], "additionalProperties": false}, "uniqueItems": true}, "metadata": {"type": "object", "properties": {"created_at": {"type": "string", "format": "date-time"}, "updated_at": {"type": "string", "format": "date-time"}, "record_version": {"type": "integer", "minimum": 1}}, "required": ["created_at", "updated_at", "record_version"], "additionalProperties": false}, "service": {"type": "object", "properties": {"provider": {"type": "object", "properties": {"id": {"type": "string", "format": "uri"}, "name": {"type": "string"}}, "required": ["id", "name"], "additionalProperties": false}, "type": {"type": "string"}, "service_area": {"type": ["string", "null"]}, "eligibility": {"type": ["string", "null"]}, "availability": {"enum": ["listed_contact_provider", "expression_of_interest", "intake_unconfirmed", "request_subject_to_capacity", "event_dependent", "deadline_listed", "historical", "confirmed_available", "temporarily_unavailable", "closed"]}, "contact_url": {"type": ["string", "null"], "format": "uri"}, "phone": {"type": ["string", "null"]}, "email": {"type": ["string", "null"]}, "cost": {"type": ["string", "null"]}, "hours": {"type": ["string", "null"]}, "deadline": {"type": ["string", "null"], "format": "date"}, "languages": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}, "accessibility": {"type": ["string", "null"]}, "provider_confirmed_at": {"type": ["string", "null"], "format": "date"}, "review_due": {"type": ["string", "null"], "format": "date"}}, "required": ["provider", "type", "service_area", "eligibility", "availability", "contact_url", "phone", "email", "cost", "hours", "deadline", "languages", "accessibility", "provider_confirmed_at", "review_due"], "additionalProperties": false}}, "required": ["id", "local_id", "standard", "schema_version", "publisher", "title", "summary", "categories", "tags", "action_stages", "audiences", "languages", "places", "event", "source", "rights", "verification", "relationships", "metadata", "service"], "additionalProperties": false}'::jsonb);

create function fc_private.validate_standard_revision() returns trigger language plpgsql security definer set search_path='' as $$
declare doc jsonb:=new.payload->'standard_record'; schema_def jsonb;
begin
 select schema_document into schema_def from fc_private.standard_schemas where standard=doc->>'standard' and version=doc->>'schema_version';
 if doc is null or schema_def is null or not extensions.jsonb_matches_schema(schema_def::json,doc) then raise exception 'Invalid draft standard document'; end if;
 if doc->>'id' is distinct from ('urn:uuid:'||(new.payload->>'uuid')) or doc->>'local_id' is distinct from new.payload->>'id'
 or doc->>'title' is distinct from new.payload->>'title' or doc->>'summary' is distinct from new.payload->>'summary'
 or doc#>>'{source,url}' is distinct from new.payload->>'source_url'
 or doc->>'standard' is distinct from (case new.payload->>'collection' when 'source' then 'FRS' when 'media' then 'FMS' when 'help' then 'FSS' end)
 then raise exception 'Standard document and editorial identity differ'; end if;
 if doc#>>'{media,asset_url}' is not null then raise exception 'Media asset publication requires a later rights workflow'; end if;
 return new;
end $$;
create trigger standard_revision before insert on fc_private.revisions for each row execute function fc_private.validate_standard_revision();
create or replace function fc_private.public_document(p jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
begin
 -- Standard schemas disallow arbitrary fields, including internal editorial notes.
 -- Cross-record links are withheld until a public relationship projection exists.
 return (p->'standard_record') || jsonb_build_object('relationships','[]'::jsonb);
end $$;

-- Public entry points remain invokers. Privileged operations live in the private schema and enforce role/scope.
create function public.fc_my_membership() returns jsonb language sql stable security invoker set search_path='' as $$
 select to_jsonb(m) from fc_private.memberships m where user_id=auth.uid();
$$;
create view public.fc_drafts with(security_invoker=true) as
 select r.id,r.external_id,r.scope_id,r.latest_revision,r.published_revision,v.payload,v.created_at
 from fc_private.records r join fc_private.revisions v on v.id=r.latest_revision;
revoke all on public.fc_drafts from public,anon,authenticated;
grant select on public.fc_drafts to authenticated;
create function public.fc_propose(p jsonb, scope uuid, expected_revision uuid default null)
returns uuid language sql security invoker set search_path='' as $$ select fc_private.propose(p,scope,expected_revision); $$;
create function public.fc_review(revision uuid,decision text,reason text,expected_published uuid default null)
returns void language sql security invoker set search_path='' as $$ select fc_private.review(revision,decision,reason,expected_published); $$;
revoke all on function public.fc_my_membership(),public.fc_propose(jsonb,uuid,uuid),public.fc_review(uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.fc_my_membership(),public.fc_propose(jsonb,uuid,uuid),public.fc_review(uuid,text,text,uuid) to authenticated;

-- Account identities are provisioned by Supabase Auth, never by inserting passwords into SQL.
create table fc_private.pending_memberships(email text primary key,scope_id uuid not null references fc_private.scopes,role text not null check(role in ('admin','editor','contributor')));
create index on fc_private.pending_memberships(scope_id);
alter table fc_private.pending_memberships enable row level security;
revoke all on fc_private.pending_memberships from public,anon,authenticated;
create function fc_private.enroll_verified_account() returns trigger language plpgsql security definer set search_path='' as $$
declare reserved fc_private.pending_memberships;
begin
 if new.email_confirmed_at is null then return new; end if;
 select * into reserved from fc_private.pending_memberships where email=lower(new.email) for update;
 if reserved.email is not null then
  insert into fc_private.memberships(user_id,scope_id,role) values(new.id,reserved.scope_id,reserved.role) on conflict(user_id) do nothing;
  delete from fc_private.pending_memberships where email=reserved.email;
 end if;
 return new;
end $$;
create trigger flood_commons_enrollment after insert or update of email_confirmed_at on auth.users for each row execute function fc_private.enroll_verified_account();
revoke all on function fc_private.validate_standard_revision(),fc_private.enroll_verified_account() from public,anon,authenticated;
-- Lock in safe defaults for any future tables created by this migration owner.
alter default privileges in schema fc_private revoke all on tables from anon,authenticated;
