-- 007: resident flood clips (FMS) with rounded public-space locations.
--
--  * Anyone may submit a link to flood footage posted elsewhere on the web
--    (Instagram, YouTube, TikTok, ...). Submissions wait in a private inbox;
--    nothing is public until an editor approves it.
--  * Media stays link-only: the page embeds or links the original post and
--    credits its creator. Nothing is copied or hosted.
--  * Coordinates are published only for footage of public space (street,
--    highway, subway) and are rounded to a 0.0005° grid (about 50 m).
--    Footage of anywhere else is shown at neighborhood level, with no point.
--  * Anyone may ask for a published clip to be removed.

-- ---------------------------------------------------------------- helpers
create function fc_private.round_coord(x numeric) returns numeric language sql immutable set search_path='' as $$
 select round(round(x / 0.0005) * 0.0005, 4)
$$;

create function fc_private.clip_platform(url text) returns text language sql immutable set search_path='' as $$
 select case
  when url ~* '^https://([a-z0-9-]+\.)*instagram\.com/' then 'instagram'
  when url ~* '^https://([a-z0-9-]+\.)*(youtube\.com|youtu\.be)/' then 'youtube'
  when url ~* '^https://([a-z0-9-]+\.)*tiktok\.com/' then 'tiktok'
  when url ~* '^https://([a-z0-9-]+\.)*(x\.com|twitter\.com)/' then 'x'
  when url ~* '^https://([a-z0-9-]+\.)*facebook\.com/' then 'facebook'
  when url ~* '^https://([a-z0-9-]+\.)*reddit\.com/' then 'reddit'
  else 'web' end
$$;

-- Representative depth for each choice residents can make (cm).
create function fc_private.depth_cm(depth text) returns numeric language sql immutable set search_path='' as $$
 select case depth when 'ankle' then 10 when 'knee' then 45 when 'waist' then 90 when 'above_waist' then 130 end
$$;

-- ---------------------------------------------------------------- inboxes
create table fc_private.clip_submissions(
 id uuid primary key default gen_random_uuid(),
 url text not null check (url ~ '^https://[^[:space:]]+$' and length(url) <= 500),
 platform text not null,
 media_type text not null check (media_type in ('video','photograph')),
 location_type text not null check (location_type in ('street','highway','subway','other')),
 lon numeric, lat numeric,
 place_name text not null check (length(trim(place_name)) between 2 and 120),
 depth text not null check (depth in ('ankle','knee','waist','above_waist','unknown')),
 observed_on date check (observed_on >= '1990-01-01'),
 storm text check (length(storm) <= 120),
 caption text check (length(caption) <= 1000),
 creator text check (length(creator) <= 120),
 contact_email text check (length(contact_email) <= 254),
 consent boolean not null check (consent),
 status text not null default 'pending' check (status in ('pending','approved','rejected')),
 record_id uuid references fc_private.records,
 review_note text, reviewed_by uuid, reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 check ((location_type = 'other') = (lon is null and lat is null)),
 check (lon is null or (lon between -74.30 and -73.65 and lat between 40.45 and 40.95))
);
create index on fc_private.clip_submissions(status, created_at);
create index on fc_private.clip_submissions(url);

create table fc_private.removal_requests(
 id uuid primary key default gen_random_uuid(),
 record_id uuid not null references fc_private.records,
 reason text not null check (length(trim(reason)) between 3 and 1000),
 contact text check (length(contact) <= 254),
 status text not null default 'open' check (status in ('open','removed','dismissed')),
 resolved_by uuid, resolved_at timestamptz, note text,
 created_at timestamptz not null default now()
);
create index on fc_private.removal_requests(status, created_at);
create index on fc_private.removal_requests(record_id);

alter table fc_private.clip_submissions enable row level security;
alter table fc_private.removal_requests enable row level security;
revoke all on fc_private.clip_submissions, fc_private.removal_requests from public, anon, authenticated;
grant select on fc_private.clip_submissions, fc_private.removal_requests to authenticated;
create policy member_read on fc_private.clip_submissions for select to authenticated using (fc_private.is_member());
create policy member_read on fc_private.removal_requests for select to authenticated using (fc_private.is_member());

-- ---------------------------------------------------------------- public entry points
-- Submit a clip. Anyone may call this; the inbox is readable by members only.
create function public.fc_submit_clip(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare v_url text := trim(p->>'url'); v_loc text := p->>'location_type'; v_observed date := nullif(p->>'observed_on','')::date; result uuid;
begin
 if (select count(*) from fc_private.clip_submissions where created_at > now() - interval '1 hour') >= 100 then
  raise exception 'Too many submissions right now. Please try again later.';
 end if;
 if v_observed > current_date + 1 then raise exception 'The date cannot be in the future'; end if;
 if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Consent is required'; end if;
 select s.id into result from fc_private.clip_submissions s where s.url = v_url and s.status <> 'rejected';
 if result is not null then return result; end if;
 insert into fc_private.clip_submissions(url, platform, media_type, location_type, lon, lat, place_name, depth, observed_on, storm, caption, creator, contact_email, consent)
 values (v_url, fc_private.clip_platform(v_url), coalesce(p->>'media_type','video'), v_loc,
  case when v_loc <> 'other' then fc_private.round_coord((p->>'lon')::numeric) end,
  case when v_loc <> 'other' then fc_private.round_coord((p->>'lat')::numeric) end,
  trim(p->>'place_name'), coalesce(p->>'depth','unknown'), v_observed,
  nullif(trim(p->>'storm'),''), nullif(trim(p->>'caption'),''), nullif(trim(p->>'creator'),''),
  nullif(lower(trim(p->>'contact_email')),''), true)
 returning id into result;
 return result;
end $$;

-- Ask for a published clip (or any published record) to be taken down.
create function public.fc_request_removal(record uuid, reason text, contact text default null) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if (select count(*) from fc_private.removal_requests where created_at > now() - interval '1 hour') >= 50 then
  raise exception 'Too many requests right now. Please try again later.';
 end if;
 if not exists (select 1 from public.fc_catalog where id = record) then raise exception 'Record not found'; end if;
 insert into fc_private.removal_requests(record_id, reason, contact) values (record, trim(reason), nullif(trim(contact),'')) returning id into result;
 return result;
end $$;

-- ---------------------------------------------------------------- editor actions
-- Approve a submission: build the FMS record from it (with optional editor
-- edits), propose it, and publish it as a public record.
create function fc_private.approve_clip(submission uuid, edits jsonb default '{}', scope uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare s fc_private.clip_submissions; rid uuid := gen_random_uuid(); rev uuid; doc jsonb; stamp text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
 loc text; depth text; place text; storm text; observed date; point jsonb := null;
begin
 select * into s from fc_private.clip_submissions where id = submission for update;
 if s.id is null or s.status <> 'pending' then raise exception 'submission is not pending'; end if;
 if scope is null then select scope_id into scope from fc_private.memberships where user_id = fc_private.uid() and active; end if;
 if not fc_private.allowed(scope, array['editor','admin']) then raise exception 'editor required' using errcode='42501'; end if;
 loc := coalesce(edits->>'location_type', s.location_type);
 depth := coalesce(edits->>'depth', s.depth);
 place := coalesce(edits->>'place_name', s.place_name);
 storm := coalesce(edits->>'storm', s.storm);
 observed := coalesce((edits->>'observed_on')::date, s.observed_on);
 if loc not in ('street','highway','subway','other') or depth not in ('ankle','knee','waist','above_waist','unknown') then raise exception 'invalid edit'; end if;
 if loc <> 'other' then
  if s.lon is null then raise exception 'a public-space clip needs a map point'; end if;
  point := jsonb_build_object('type','Point','coordinates', jsonb_build_array(fc_private.round_coord(s.lon), fc_private.round_coord(s.lat)));
 end if;
 doc := jsonb_build_object(
  'id', 'urn:uuid:' || rid,
  'local_id', 'clip-' || left(rid::text, 8),
  'standard', 'FMS', 'schema_version', '0.1.0',
  'publisher', jsonb_build_object('id', 'https://github.com/gibsonchu/flood-commons', 'name', 'Flood Commons'),
  'title', coalesce(edits->>'title', case when storm is not null then storm || ' — ' || place else 'Flooding — ' || place end),
  'summary', coalesce(edits->>'summary', s.caption, 'Resident-submitted flood footage near ' || place || '.'),
  'categories', case loc when 'street' then '["observed_impacts","public_space"]' when 'other' then '["observed_impacts"]' else '["observed_impacts","transportation"]' end::jsonb,
  'tags', jsonb_build_array('location:' || loc, 'platform:' || s.platform, 'depth:' || depth),
  'action_stages', '["respond"]'::jsonb, 'audiences', '["residents"]'::jsonb, 'languages', '["en"]'::jsonb,
  'places', jsonb_build_array(jsonb_build_object('id', 'clip-' || left(rid::text, 8), 'name', place, 'relation', 'observed_at',
    'precision', case when point is null then 'named_area' else 'approximate' end, 'geometry', point)),
  'event', case when storm is null then null else jsonb_build_object('id', 'storm:' || trim(both '-' from regexp_replace(lower(storm), '[^a-z0-9]+', '-', 'g')), 'name', storm,
    'date_text', coalesce(to_char(observed, 'FMMonth FMDD, YYYY'), 'Date not given')) end,
  'source', jsonb_build_object('url', s.url, 'organization', initcap(s.platform), 'checked_at', to_char(current_date, 'YYYY-MM-DD'), 'evidence_status', 'website_documented'),
  'rights', jsonb_build_object('status', 'not_assessed', 'license', null, 'license_url', null, 'attribution', s.creator),
  'verification', jsonb_build_object('status', 'source_checked', 'method', 'An editor viewed the original post before publishing.', 'verified_at', to_char(current_date, 'YYYY-MM-DD')),
  'relationships', '[]'::jsonb,
  'metadata', jsonb_build_object('created_at', stamp, 'updated_at', stamp, 'record_version', 1),
  'media', jsonb_build_object('type', s.media_type, 'creator', s.creator, 'capture_date', to_char(observed, 'YYYY-MM-DD'), 'capture_date_text', null,
    'asset_url', null, 'alt_text', edits->>'alt_text', 'duration_seconds', null, 'evidence_kind', null,
    'observation', jsonb_build_object('observed_at', null, 'description', coalesce(edits->>'summary', s.caption, 'Resident-submitted flood footage.'),
      'flood_depth_cm', fc_private.depth_cm(depth), 'damage_classification', 'unknown')));
 rev := fc_private.propose_standard(doc, scope, 'public', fc_private.uid());
 perform fc_private.review(rev, 'publish', coalesce(edits->>'note', 'Approved resident clip submission.'), null);
 update fc_private.clip_submissions set status = 'approved', record_id = rid, reviewed_by = fc_private.uid(), reviewed_at = now(), review_note = edits->>'note' where id = s.id;
 insert into fc_private.audit_events(actor, action, target) values (fc_private.uid(), 'approve_clip', s.id::text);
 return rid;
end $$;

create function fc_private.reject_clip(submission uuid, note text) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists (select 1 from fc_private.memberships where user_id = fc_private.uid() and active and role in ('editor','admin')) then raise exception 'editor required' using errcode='42501'; end if;
 update fc_private.clip_submissions set status = 'rejected', reviewed_by = fc_private.uid(), reviewed_at = now(), review_note = note where id = submission and status = 'pending';
 if not found then raise exception 'submission is not pending'; end if;
 insert into fc_private.audit_events(actor, action, target) values (fc_private.uid(), 'reject_clip', submission::text);
end $$;

-- Resolve a removal request: 'remove' archives the publication, 'dismiss' keeps it.
create function fc_private.resolve_removal(request uuid, action text, note text) returns void language plpgsql security definer set search_path='' as $$
declare q fc_private.removal_requests; r fc_private.records;
begin
 select * into q from fc_private.removal_requests where id = request for update;
 if q.id is null or q.status <> 'open' then raise exception 'request is not open'; end if;
 select * into r from fc_private.records where id = q.record_id;
 if not fc_private.allowed(r.scope_id, array['editor','admin']) then raise exception 'editor required' using errcode='42501'; end if;
 if action = 'remove' then
  if r.published_revision is not null then perform fc_private.review(r.published_revision, 'archive', coalesce(note, 'Removal requested'), r.published_revision); end if;
 elsif action <> 'dismiss' then raise exception 'action must be remove or dismiss';
 end if;
 update fc_private.removal_requests set status = case action when 'remove' then 'removed' else 'dismissed' end,
  resolved_by = fc_private.uid(), resolved_at = now(), note = resolve_removal.note where id = q.id;
 insert into fc_private.audit_events(actor, action, target) values (fc_private.uid(), 'removal:' || action, q.id::text);
end $$;

-- ---------------------------------------------------------------- location guard
-- Replaces 005: exact points are never published. Approximate points are
-- allowed only on FMS clips of public space, and are rounded here as well.
create or replace function fc_private.guard_public_location() returns trigger language plpgsql set search_path='' as $$
declare places jsonb := '[]'; p jsonb; public_space boolean;
begin
 public_space := new.document->>'standard' = 'FMS'
  and new.document->'tags' ?| array['location:street','location:highway','location:subway'];
 for p in select value from jsonb_array_elements(coalesce(new.document->'places','[]')) loop
  if p->>'precision' = 'exact' then raise exception 'Exact locations are never published'; end if;
  if p->>'precision' = 'approximate' or coalesce(p->'geometry','null'::jsonb) <> 'null'::jsonb then
   if not public_space or p->>'precision' <> 'approximate' or p#>>'{geometry,type}' is distinct from 'Point' then
    raise exception 'Map points are published only for clips of streets, highways, or subways';
   end if;
   p := jsonb_set(p, '{geometry,coordinates}', jsonb_build_array(
    fc_private.round_coord((p#>>'{geometry,coordinates,0}')::numeric), fc_private.round_coord((p#>>'{geometry,coordinates,1}')::numeric)));
  end if;
  places := places || jsonb_build_array(p);
 end loop;
 if new.document ? 'places' then new.document := jsonb_set(new.document, '{places}', places); end if;
 return new;
end $$;

-- ---------------------------------------------------------------- workspace access
create view public.fc_clip_inbox with (security_invoker = true) as
 select * from fc_private.clip_submissions;
create view public.fc_removal_inbox with (security_invoker = true) as
 select q.*, c.document->>'title' as record_title from fc_private.removal_requests q left join public.fc_catalog c on c.id = q.record_id;
revoke all on public.fc_clip_inbox, public.fc_removal_inbox from public, anon, authenticated;
grant select on public.fc_clip_inbox, public.fc_removal_inbox to authenticated;

create function public.fc_approve_clip(submission uuid, edits jsonb default '{}') returns uuid language sql security invoker set search_path='' as $$ select fc_private.approve_clip(submission, edits); $$;
create function public.fc_reject_clip(submission uuid, note text) returns void language sql security invoker set search_path='' as $$ select fc_private.reject_clip(submission, note); $$;
create function public.fc_resolve_removal(request uuid, action text, note text) returns void language sql security invoker set search_path='' as $$ select fc_private.resolve_removal(request, action, note); $$;

revoke all on function fc_private.round_coord(numeric), fc_private.clip_platform(text), fc_private.depth_cm(text),
 fc_private.approve_clip(uuid,jsonb,uuid), fc_private.reject_clip(uuid,text), fc_private.resolve_removal(uuid,text,text),
 public.fc_submit_clip(jsonb), public.fc_request_removal(uuid,text,text),
 public.fc_approve_clip(uuid,jsonb), public.fc_reject_clip(uuid,text), public.fc_resolve_removal(uuid,text,text) from public, anon, authenticated;
grant execute on function public.fc_submit_clip(jsonb), public.fc_request_removal(uuid,text,text) to anon, authenticated;
grant execute on function fc_private.approve_clip(uuid,jsonb,uuid), fc_private.reject_clip(uuid,text), fc_private.resolve_removal(uuid,text,text),
 fc_private.round_coord(numeric), fc_private.clip_platform(text), fc_private.depth_cm(text),
 public.fc_approve_clip(uuid,jsonb), public.fc_reject_clip(uuid,text), public.fc_resolve_removal(uuid,text,text) to authenticated;
