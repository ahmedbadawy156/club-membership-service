-- Membership request submission: rate limiting and the atomic insert used
-- by POST /membership-api/membership-requests.
--
-- Everything here is called only by the membership-api Edge Function with
-- the secret key (service_role). Browsers have no access.

-- 1. Database-level limits on applicant data (defence in depth; the Edge
--    Function validates the same rules first and returns 400).

alter table public.profiles
  add constraint profiles_full_name_length
    check (char_length(full_name) between 2 and 100),
  add constraint profiles_email_length
    check (char_length(email) between 3 and 254);

alter table public.membership_requests
  add constraint membership_requests_full_name_length
    check (char_length(full_name) between 2 and 100),
  add constraint membership_requests_email_length
    check (char_length(email) between 3 and 254);

-- 2. Submission attempts per source address. Only a salted SHA-256 hash of
--    the address is stored, never the raw IP.

create table public.membership_request_attempts (
  attempt_id uuid primary key default gen_random_uuid(),
  ip_hash text not null
    check (ip_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);

create index membership_request_attempts_ip_recent_idx
  on public.membership_request_attempts (ip_hash, created_at desc);

alter table public.membership_request_attempts enable row level security;

revoke all on public.membership_request_attempts from anon, authenticated;
grant all on public.membership_request_attempts to service_role;

-- 3. Rate-limit check. Returns 'ok' and records the attempt, or returns
--    'ip_limit' / 'total_limit' without recording anything. The Edge
--    Function maps both limits to 429.
--
--    An advisory lock per address hash makes concurrent requests from the
--    same address queue up, so they cannot all pass the count at once.

create function public.record_membership_request_attempt(
  p_ip_hash text,
  p_max_per_window integer default 5,
  p_window interval default interval '1 hour',
  p_max_pending_total integer default 200
)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_recent integer;
  v_pending integer;
begin
  if p_ip_hash is null or p_ip_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid ip hash' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_ip_hash, 0));

  -- Keep the table small: drop this address's attempts outside the window.
  delete from public.membership_request_attempts
  where ip_hash = p_ip_hash
    and created_at < now() - p_window;

  select count(*) into v_recent
  from public.membership_request_attempts
  where ip_hash = p_ip_hash
    and created_at >= now() - p_window;

  if v_recent >= p_max_per_window then
    return 'ip_limit';
  end if;

  select count(*) into v_pending
  from public.membership_requests
  where status = 'pending';

  if v_pending >= p_max_pending_total then
    return 'total_limit';
  end if;

  insert into public.membership_request_attempts (ip_hash)
  values (p_ip_hash);

  return 'ok';
end;
$$;

-- 4. Atomic submission. Inserts the inactive profile and the pending
--    request in one transaction. A duplicate email raises unique_violation
--    (23505), which the Edge Function maps to 409 and then deletes the
--    Auth user it just created.

create function public.submit_membership_request(
  p_user_id uuid,
  p_full_name text,
  p_email text
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_id uuid;
begin
  insert into public.profiles (user_id, full_name, email)
  values (p_user_id, p_full_name, p_email);

  insert into public.membership_requests (user_id, full_name, email)
  values (p_user_id, p_full_name, p_email)
  returning request_id into v_request_id;

  return v_request_id;
end;
$$;

-- 5. Postgres grants EXECUTE on new functions to PUBLIC, and Supabase
--    exposes public-schema functions at /rest/v1/rpc/. Remove that access
--    so only service_role can call them.

revoke execute on function
  public.record_membership_request_attempt(text, integer, interval, integer)
  from public, anon, authenticated;
revoke execute on function
  public.submit_membership_request(uuid, text, text)
  from public, anon, authenticated;

grant execute on function
  public.record_membership_request_attempt(text, integer, interval, integer)
  to service_role;
grant execute on function
  public.submit_membership_request(uuid, text, text)
  to service_role;
