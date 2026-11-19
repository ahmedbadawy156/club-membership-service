-- Role changes used by PATCH /membership-api/members/:id/role.
--
-- Called only with the secret key (service_role). Browsers have no access.
--
-- Custom error codes (SQLSTATE), in addition to those in the officer
-- review migration:
--   MB403  actor is not an active officer
--   MB404  target user not found
--   MB409  target is not an active (approved) member
--   MB410  change would leave the club with no active officer

create function public.change_member_role(
  p_target_id uuid,
  p_actor_id uuid,
  p_new_role text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_target public.profiles%rowtype;
  v_other_officers integer;
begin
  if p_new_role is null or p_new_role not in ('member', 'officer') then
    raise exception 'role must be member or officer' using errcode = '22023';
  end if;

  -- Roster lock: every role change waits for the previous one to commit,
  -- so two officers cannot demote each other at the same moment and leave
  -- no officer behind.
  perform pg_advisory_xact_lock(hashtextextended('officer_roster', 0));

  perform 1
  from public.profiles
  where user_id = p_actor_id
    and role = 'officer'
    and active;
  if not found then
    raise exception 'actor is not an active officer' using errcode = 'MB403';
  end if;

  select * into v_target
  from public.profiles
  where user_id = p_target_id
  for update;
  if not found then
    raise exception 'user not found' using errcode = 'MB404';
  end if;

  if not v_target.active then
    raise exception 'user is not an active member' using errcode = 'MB409';
  end if;

  -- Same role: nothing to change. Returned so a failed Auth update can be
  -- retried by sending the same request again.
  if v_target.role = p_new_role then
    return jsonb_build_object(
      'userId', v_target.user_id,
      'role', v_target.role,
      'previousRole', v_target.role,
      'changed', false
    );
  end if;

  if v_target.role = 'officer' and p_new_role = 'member' then
    select count(*) into v_other_officers
    from public.profiles
    where role = 'officer'
      and active
      and user_id <> p_target_id;
    if v_other_officers = 0 then
      raise exception 'cannot demote the last active officer'
        using errcode = 'MB410';
    end if;
  end if;

  update public.profiles
  set role = p_new_role
  where user_id = p_target_id;

  insert into public.audit_log (event_type, actor_id, target_id, metadata)
  values (
    'role_changed', p_actor_id, p_target_id,
    jsonb_build_object('old_role', v_target.role, 'new_role', p_new_role)
  );

  return jsonb_build_object(
    'userId', v_target.user_id,
    'role', p_new_role,
    'previousRole', v_target.role,
    'changed', true
  );
end;
$$;

revoke execute on function
  public.change_member_role(uuid, uuid, text)
  from public, anon, authenticated;

grant execute on function
  public.change_member_role(uuid, uuid, text)
  to service_role;
