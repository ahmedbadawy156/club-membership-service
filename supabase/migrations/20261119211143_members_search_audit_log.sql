-- Officer read routes: GET /membership-api/members and GET /audit-log.
-- Also makes audit_log append-only for the secret key (service_role).
--
-- Called only with the secret key (service_role). Browsers have no access.

-- 1. Member search. The search text is a parameter, never part of a
--    filter string, and LIKE wildcards in it are escaped so "%" or "_"
--    match themselves. Returns { members: [...], total }.

create function public.search_members(
  p_search text default null,
  p_status text default 'active',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_pattern text;
  v_result jsonb;
begin
  if p_status is null or p_status not in ('active', 'inactive', 'all') then
    raise exception 'status must be active, inactive or all' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be 1 to 100' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'offset must be 0 or more' using errcode = '22023';
  end if;
  if p_search is not null and char_length(p_search) > 100 then
    raise exception 'search must be at most 100 characters' using errcode = '22023';
  end if;

  if p_search is not null and btrim(p_search) <> '' then
    v_pattern := '%' || replace(replace(replace(btrim(p_search),
      '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  with matched as (
    select p.user_id, p.full_name, p.email, p.role, p.active, p.created_at
    from public.profiles p
    where (p_status = 'all'
           or (p_status = 'active' and p.active)
           or (p_status = 'inactive' and not p.active))
      and (v_pattern is null
           or p.full_name ilike v_pattern escape '\'
           or p.email ilike v_pattern escape '\')
  ),
  page as (
    select *
    from matched
    order by lower(full_name), user_id
    limit p_limit offset p_offset
  )
  select jsonb_build_object(
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', user_id,
        'fullName', full_name,
        'email', email,
        'role', role,
        'active', active,
        'createdAt', created_at
      ) order by lower(full_name), user_id)
      from page
    ), '[]'::jsonb),
    'total', (select count(*) from matched)
  ) into v_result;

  return v_result;
end;
$$;

-- 2. Audit log, newest first. Paging uses the logId of the last entry
--    seen (p_before): rows strictly older by (created_at, log_id), so no
--    row is skipped or repeated even when timestamps are equal. Names are
--    joined; emails and other profile fields are not returned.

create index audit_log_created_desc_idx
  on public.audit_log (created_at desc, log_id desc);

create function public.list_audit_log(
  p_type text default null,
  p_limit integer default 50,
  p_before uuid default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_before_time timestamptz;
  v_result jsonb;
begin
  if p_type is not null and p_type not in (
    'login_failure', 'account_locked', 'membership_approved',
    'membership_rejected', 'role_changed'
  ) then
    raise exception 'unknown event type' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be 1 to 100' using errcode = '22023';
  end if;

  if p_before is not null then
    select created_at into v_before_time
    from public.audit_log
    where log_id = p_before;
    if not found then
      raise exception 'unknown cursor' using errcode = '22023';
    end if;
  end if;

  with page as (
    select a.log_id, a.event_type, a.created_at, a.metadata,
           a.actor_id, actor.full_name as actor_name,
           a.target_id, target.full_name as target_name
    from public.audit_log a
    left join public.profiles actor on actor.user_id = a.actor_id
    left join public.profiles target on target.user_id = a.target_id
    where (p_type is null or a.event_type = p_type)
      and (p_before is null
           or (a.created_at, a.log_id) < (v_before_time, p_before))
    order by a.created_at desc, a.log_id desc
    limit p_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'logId', log_id,
    'eventType', event_type,
    'createdAt', created_at,
    'actor', case when actor_id is null then null
             else jsonb_build_object('userId', actor_id, 'fullName', actor_name) end,
    'target', case when target_id is null then null
              else jsonb_build_object('userId', target_id, 'fullName', target_name) end,
    'metadata', metadata
  ) order by created_at desc, log_id desc), '[]'::jsonb)
  into v_result
  from page;

  return v_result;
end;
$$;

-- 3. Permissions for the new functions.

revoke execute on function
  public.search_members(text, text, integer, integer)
  from public, anon, authenticated;
revoke execute on function
  public.list_audit_log(text, integer, uuid)
  from public, anon, authenticated;

grant execute on function
  public.search_members(text, text, integer, integer)
  to service_role;
grant execute on function
  public.list_audit_log(text, integer, uuid)
  to service_role;

-- 4. Append-only audit log: the secret key can add and read entries but
--    not change or remove them. The table owner (postgres) keeps full
--    rights for administration.

revoke update, delete, truncate on public.audit_log from service_role;
