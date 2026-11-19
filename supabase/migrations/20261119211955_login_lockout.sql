-- Login lockout and per-address limit for POST /membership-api/auth/login.
--
-- Called only with the secret key (service_role). Browsers have no access.
--
-- Rules: 5 failed logins lock the account for 15 minutes. Each attempt is
-- counted as a failure before the password is checked, so a burst of
-- simultaneous guesses cannot get more than 5 past the counter. A
-- successful login resets the counter.
--
-- Audit rows never contain an email, password or IP address.

-- 1. Login attempts per source address (salted SHA-256 hash only).

create table public.login_attempts (
  attempt_id uuid primary key default gen_random_uuid(),
  ip_hash text not null
    check (ip_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);

create index login_attempts_ip_recent_idx
  on public.login_attempts (ip_hash, created_at desc);

alter table public.login_attempts enable row level security;

revoke all on public.login_attempts from anon, authenticated;
grant all on public.login_attempts to service_role;

-- 2. Per-address limit. Returns 'ok' and records the attempt, or
--    'ip_limit' without recording it.

create function public.record_login_ip_attempt(
  p_ip_hash text,
  p_max_per_window integer default 20,
  p_window interval default interval '15 minutes'
)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_recent integer;
begin
  if p_ip_hash is null or p_ip_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid ip hash' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('login:' || p_ip_hash, 0));

  delete from public.login_attempts
  where ip_hash = p_ip_hash
    and created_at < now() - p_window;

  select count(*) into v_recent
  from public.login_attempts
  where ip_hash = p_ip_hash
    and created_at >= now() - p_window;

  if v_recent >= p_max_per_window then
    return 'ip_limit';
  end if;

  insert into public.login_attempts (ip_hash) values (p_ip_hash);
  return 'ok';
end;
$$;

-- Shared by start and finish: lock the account if it is not locked yet.
-- Returns true only for the call that actually locked it.

create function public.lock_account_if_needed(
  p_user_id uuid,
  p_lock_duration interval
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_locked_until timestamptz;
begin
  update public.profiles
  set locked_until = now() + p_lock_duration
  where user_id = p_user_id
    and (locked_until is null or locked_until <= now())
  returning locked_until into v_locked_until;

  if not found then
    return false;
  end if;

  insert into public.audit_log (event_type, actor_id, target_id, metadata)
  values (
    'account_locked', null, p_user_id,
    jsonb_build_object('locked_until', v_locked_until)
  );
  return true;
end;
$$;

-- 3. Start an attempt. Unknown email: allowed (Auth will refuse it), so
--    unknown and known emails take the same path. Known email: refuse if
--    locked; otherwise count the attempt now.
--
--    Returns { userId, active, allowed, retryAfterSeconds, newlyLocked }.

create function public.start_login_attempt(
  p_email text,
  p_max_failures integer default 5,
  p_lock_duration interval default interval '15 minutes'
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_newly_locked boolean := false;
begin
  select * into v_profile
  from public.profiles
  where lower(email) = lower(btrim(p_email))
  for update;

  if not found then
    return jsonb_build_object(
      'userId', null, 'active', false, 'allowed', true,
      'retryAfterSeconds', 0, 'newlyLocked', false
    );
  end if;

  -- Still locked.
  if v_profile.locked_until is not null and v_profile.locked_until > now() then
    return jsonb_build_object(
      'userId', v_profile.user_id, 'active', v_profile.active,
      'allowed', false,
      'retryAfterSeconds',
        ceil(extract(epoch from v_profile.locked_until - now()))::integer,
      'newlyLocked', false
    );
  end if;

  -- An expired lock starts a fresh count.
  if v_profile.locked_until is not null then
    update public.profiles
    set failed_login_count = 0, locked_until = null
    where user_id = v_profile.user_id;
    v_profile.failed_login_count := 0;
  end if;

  -- Simultaneous attempts have already used every slot: lock now.
  if v_profile.failed_login_count >= p_max_failures then
    v_newly_locked := public.lock_account_if_needed(
      v_profile.user_id, p_lock_duration);
    return jsonb_build_object(
      'userId', v_profile.user_id, 'active', v_profile.active,
      'allowed', false,
      'retryAfterSeconds', ceil(extract(epoch from p_lock_duration))::integer,
      'newlyLocked', v_newly_locked
    );
  end if;

  update public.profiles
  set failed_login_count = failed_login_count + 1
  where user_id = v_profile.user_id;

  return jsonb_build_object(
    'userId', v_profile.user_id, 'active', v_profile.active,
    'allowed', true, 'retryAfterSeconds', 0, 'newlyLocked', false
  );
end;
$$;

-- 4. Finish an attempt. Success resets the counter. Failure writes
--    login_failure and locks the account once the counter reaches the
--    maximum. Returns { newlyLocked }.

create function public.finish_login_attempt(
  p_user_id uuid,
  p_success boolean,
  p_max_failures integer default 5,
  p_lock_duration interval default interval '15 minutes'
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count integer;
  v_newly_locked boolean := false;
begin
  if p_success then
    update public.profiles
    set failed_login_count = 0, locked_until = null
    where user_id = p_user_id;
    return jsonb_build_object('newlyLocked', false);
  end if;

  select failed_login_count into v_count
  from public.profiles
  where user_id = p_user_id
  for update;
  if not found then
    return jsonb_build_object('newlyLocked', false);
  end if;

  insert into public.audit_log (event_type, actor_id, target_id, metadata)
  values ('login_failure', null, p_user_id, '{}'::jsonb);

  if v_count >= p_max_failures then
    v_newly_locked := public.lock_account_if_needed(p_user_id, p_lock_duration);
  end if;

  return jsonb_build_object('newlyLocked', v_newly_locked);
end;
$$;

-- 5. Permissions.

revoke execute on function public.record_login_ip_attempt(text, integer, interval)
  from public, anon, authenticated;
revoke execute on function public.lock_account_if_needed(uuid, interval)
  from public, anon, authenticated;
revoke execute on function public.start_login_attempt(text, integer, interval)
  from public, anon, authenticated;
revoke execute on function public.finish_login_attempt(uuid, boolean, integer, interval)
  from public, anon, authenticated;

grant execute on function public.record_login_ip_attempt(text, integer, interval)
  to service_role;
grant execute on function public.lock_account_if_needed(uuid, interval)
  to service_role;
grant execute on function public.start_login_attempt(text, integer, interval)
  to service_role;
grant execute on function public.finish_login_attempt(uuid, boolean, integer, interval)
  to service_role;
