create function fc_private.check_standard_consistency() returns trigger language plpgsql security definer set search_path='' as $$
declare p jsonb:=new.payload; d jsonb:=new.payload->'standard_record'; k text;
begin
 if d->'categories' is distinct from p->'topics' or d->'action_stages' is distinct from p->'action_stages' or d->'audiences' is distinct from p->'audiences'
 or d#>>'{source,evidence_status}' is distinct from p->>'evidence_status' or d#>>'{rights,status}' is distinct from p->>'rights_status' then raise exception 'Standard and editorial classifications differ'; end if;
 if p->>'collection'='help' then
  foreach k in array array['service_area','eligibility','availability','contact_url','phone','email','cost','hours','deadline','accessibility'] loop
   if d#>array['service',k] is distinct from p#>array['details',k] then raise exception 'Standard and editorial service fields differ'; end if;
  end loop;
  if d#>>'{service,provider_confirmed_at}' is distinct from p->>'provider_confirmed_at' or d#>>'{service,review_due}' is distinct from p->>'next_review_due' then raise exception 'Standard and editorial service dates differ'; end if;
 end if;
 if p->>'collection'='media' then
  foreach k in array array['creator','capture_date','capture_date_text','duration_seconds','evidence_kind'] loop
   if d#>array['media',k] is distinct from p#>array['details',k] then raise exception 'Standard and editorial media fields differ'; end if;
  end loop;
 end if;
 return new;
end $$;
create trigger standard_consistency before insert on fc_private.revisions for each row execute function fc_private.check_standard_consistency();
revoke all on function fc_private.check_standard_consistency() from public,anon,authenticated;
create or replace function fc_private.public_document(p jsonb) returns jsonb language plpgsql stable set search_path='' as $$
begin
 return (p->'standard_record') || jsonb_build_object('relationships','[]'::jsonb,'verification',jsonb_build_object('status','reviewed','method','Flood Commons editorial review','verified_at',current_date));
end $$;
create table public.fc_relationships(
 source_id uuid references public.fc_catalog on delete cascade,
 target_id uuid references public.fc_catalog on delete cascade,
 relation text not null,primary key(source_id,target_id,relation)
);
create index on public.fc_relationships(target_id);
alter table public.fc_relationships enable row level security;
revoke all on public.fc_relationships from public,anon,authenticated;
grant select on public.fc_relationships to anon,authenticated;
create policy published_links on public.fc_relationships for select to anon,authenticated using(true);
create function fc_private.refresh_public_relationships() returns trigger language plpgsql security definer set search_path='' as $$
begin
 delete from public.fc_relationships where source_id=new.id;
 insert into public.fc_relationships(source_id,target_id,relation)
 select c.id,t.id,r.relation from fc_private.relationships r
 join public.fc_catalog c on c.revision_id=r.revision_id
 join public.fc_catalog t on t.id=r.target_id
 where c.id=new.id or t.id=new.id on conflict do nothing;
 return new;
end $$;
revoke all on function fc_private.refresh_public_relationships() from public,anon,authenticated;
create trigger refresh_public_relationships after insert or update on public.fc_catalog for each row execute function fc_private.refresh_public_relationships();
create view public.fc_records with(security_invoker=true) as
 select c.id,c.external_id,c.collection,c.published_at,
 c.document||jsonb_build_object('relationships',coalesce((select jsonb_agg(jsonb_build_object('target_id','urn:uuid:'||l.target_id::text,'relation',l.relation)) from public.fc_relationships l where l.source_id=c.id),'[]'::jsonb)) as document
 from public.fc_catalog c;
revoke all on public.fc_records from public,anon,authenticated;
grant select on public.fc_records to anon,authenticated;
