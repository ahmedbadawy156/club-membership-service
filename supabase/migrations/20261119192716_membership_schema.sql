create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete restrict,
  full_name text not null,
  email text not null,
  role text not null default 'member'
    check (role in ('member', 'officer')),
  active boolean not null default false,
  failed_login_count integer not null default 0
    check (failed_login_count >= 0),
  locked_until timestamptz,
  created_at timestamptz not null default now()
);

create unique index profiles_email_lower_key
  on public.profiles (lower(email));

create table public.membership_requests (
  request_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  full_name text not null,
  email text not null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(user_id) on delete restrict,
  check (
    (status = 'pending' and reviewed_at is null and reviewed_by is null)
    or
    (status in ('approved', 'rejected')
      and reviewed_at is not null
      and reviewed_by is not null)
  )
);

create unique index membership_requests_one_pending_email_key
  on public.membership_requests (lower(email))
  where status = 'pending';

create table public.audit_log (
  log_id uuid primary key default gen_random_uuid(),
  event_type text not null
    check (event_type in (
      'login_failure',
      'account_locked',
      'membership_approved',
      'membership_rejected',
      'role_changed'
    )),
  actor_id uuid references public.profiles(user_id) on delete restrict,
  target_id uuid references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object')
);

alter table public.profiles enable row level security;
alter table public.membership_requests enable row level security;
alter table public.audit_log enable row level security;

revoke all on public.profiles from anon, authenticated;
revoke all on public.membership_requests from anon, authenticated;
revoke all on public.audit_log from anon, authenticated;

grant all on public.profiles to service_role;
grant all on public.membership_requests to service_role;
grant all on public.audit_log to service_role;