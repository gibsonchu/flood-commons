-- The draft schemas permit geometry, but this hosted pilot does not publish it.
create function fc_private.guard_public_location() returns trigger
language plpgsql set search_path='' as $$
begin
 if exists(select 1 from jsonb_array_elements(new.document->'places') p
 where p->>'precision' in ('exact','approximate') or p->'geometry' <> 'null'::jsonb)
 then raise exception 'Coordinate publication requires a privacy review workflow'; end if;
 return new;
end $$;
revoke all on function fc_private.guard_public_location() from public,anon,authenticated;
create trigger public_location_guard before insert or update on public.fc_catalog
for each row execute function fc_private.guard_public_location();
