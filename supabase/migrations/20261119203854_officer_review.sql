-- Officer review: first-officer bootstrap and the approve/reject workflow
-- used by PATCH /membership-api/membership-requests/:id.
--
-- Called only with the secret key (service_role). Browsers have no access.
--
-- Custom error codes (SQLSTATE) read by the Edge Function and scripts:
--   MB001  an officer already exists (bootstrap refused)
--   MB403  caller is not an active officer
--   MB404  membership request not found
--   MB409  request already decided the other way

-- 1. First officer. Refuses if any officer exists, so it can only ever
--    create one account. Run by scripts/create-officer.sh after it has
--    created the Auth user.

create function public.bootstrap_first_officer(
  p_user_id uuid,
  p_full_name text,
  p_email text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- Serialise concurrent bootstrap attempts.
  perform pg_advisory_xact_lock(hashtextextended('bootstrap_first_officer', 0));

  if exists (select 1 from public.profiles where role = 'officer') then
    raise exception 'an officer already exists' using errcode = 'MB001';
  end if;

  insert into public.profiles (user_id, full_name, email, role, active)
  values (p_user_id, p_full_name, lower(p_email), 'officer', true);

  insert into public.audit_log (event_type, actor_id, target_id, metadata)
  values (
    'role_changed', null, p_user_id,
    jsonb_build_object('reason', 'bootstrap', 'new_role', 'officer')
  );
end;
$$;

-- 2. Review a request. One transaction: checks the reviewer, locks the
--    request row, records the decision, activates the profile on approval,
--    and writes the audit log.
--
--    Repeating the same decision returns alreadyDecided = true and changes
--    nothing (so a failed Auth update can be retried). A different decision
--    on a decided request raises MB409.

create function public.review_membership_request(
  p_request_id uuid,
  p_reviewer_id uuid,
  p_decision text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_target_status text;
  v_request public.membership_requests%rowtype;
begin
  if p_decision = 'approve' then
    v_target_status := 'approved';
  elsif p_decision = 'reject' then
    v_target_status := 'rejected';
  else
    raise exception 'decision must be approve or reject' using errcode = '22023';
  end if;

  -- The reviewer must be an active officer at the moment of the decision.
  -- FOR SHARE stops a concurrent demotion from committing in between.
  perform 1
  from public.profiles
  where user_id = p_reviewer_id
    and role = 'officer'
    and active
  for share;
  if not found then
    raise exception 'reviewer is not an active officer' using errcode = 'MB403';
  end if;

  select * into v_request
  from public.membership_requests
  where request_id = p_request_id
  for update;
  if not found then
    raise exception 'membership request not found' using errcode = 'MB404';
  end if;

  if v_request.status = v_target_status then
    return jsonb_build_object(
      'userId', v_request.user_id,
      'status', v_request.status,
      'alreadyDecided', true
    );
  end if;

  if v_request.status <> 'pending' then
    raise exception 'request already decided' using errcode = 'MB409';
  end if;

  update public.membership_requests
  set status = v_target_status,
      reviewed_at = now(),
      reviewed_by = p_reviewer_id
  where request_id = p_request_id;

  if v_target_status = 'approved' then
    update public.profiles
    set active = true
    where user_id = v_request.user_id;
  end if;

  insert into public.audit_log (event_type, actor_id, target_id, metadata)
  values (
    case when v_target_status = 'approved'
      then 'membership_approved' else 'membership_rejected' end,
    p_reviewer_id,
    v_request.user_id,
    jsonb_build_object('request_id', p_request_id)
  );

  return jsonb_build_object(
    'userId', v_request.user_id,
    'status', v_target_status,
    'alreadyDecided', false
  );
end;
$$;

-- 3. Remove the default PUBLIC execute grant and the RPC exposure.

revoke execute on function
  public.bootstrap_first_officer(uuid, text, text)
  from public, anon, authenticated;
revoke execute on function
  public.review_membership_request(uuid, uuid, text)
  from public, anon, authenticated;

grant execute on function
  public.bootstrap_first_officer(uuid, text, text)
  to service_role;
grant execute on function
  public.review_membership_request(uuid, uuid, text)
  to service_role;
