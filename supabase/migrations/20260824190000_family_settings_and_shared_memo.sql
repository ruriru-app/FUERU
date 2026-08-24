-- FUERU family name editing and guardian-authored shared child memo
alter table public.child_settings
  add column if not exists shared_memo text not null default '';

create or replace function public.update_family_name(
  p_family_id uuid,
  p_name text
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $function$
declare
  v_name text := btrim(coalesce(p_name, ''));
begin
  if char_length(v_name) < 1 or char_length(v_name) > 80 then
    raise exception 'invalid_family_name';
  end if;

  if not private.is_guardian_of(p_family_id) then
    raise exception 'not_authorized';
  end if;

  update public.families
  set name = v_name
  where id = p_family_id;

  if not found then
    raise exception 'family_not_found';
  end if;

  return v_name;
end;
$function$;

create or replace function public.update_child_shared_memo(
  p_child_id uuid,
  p_memo text
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $function$
declare
  v_family_id uuid;
  v_memo text := coalesce(p_memo, '');
begin
  if char_length(v_memo) > 10000 then
    raise exception 'memo_too_long';
  end if;

  select family_id
  into v_family_id
  from public.children
  where id = p_child_id
    and archived_at is null
    and setup_state = 'active';

  if v_family_id is null then
    raise exception 'child_not_found';
  end if;

  if not private.is_guardian_of(v_family_id) then
    raise exception 'not_authorized';
  end if;

  update public.child_settings
  set shared_memo = v_memo,
      updated_at = pg_catalog.now()
  where child_id = p_child_id
    and family_id = v_family_id;

  if not found then
    raise exception 'child_settings_not_found';
  end if;

  return v_memo;
end;
$function$;

revoke all on function public.update_family_name(uuid, text) from public;
revoke all on function public.update_child_shared_memo(uuid, text) from public;
grant execute on function public.update_family_name(uuid, text) to authenticated;
grant execute on function public.update_child_shared_memo(uuid, text) to authenticated;

