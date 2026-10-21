-- Sama Nafa security-hardened multi-member foundation
-- Review and run in the Supabase SQL Editor before connecting the app.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Member',
  role text not null default 'member' check (role in ('admin','member')),
  status text not null default 'active' check (status in ('active','suspended')),
  created_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.profiles(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  kind text not null check (kind in ('deposit','withdrawal')),
  amount_xof bigint not null check (amount_xof > 0),
  note text not null default '' check (char_length(note) <= 240),
  occurred_on date not null default current_date,
  created_at timestamptz not null default now()
);

create table if not exists public.savings_goals (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  target_xof bigint not null check (target_xof > 0),
  icon text not null default '🎯',
  created_at timestamptz not null default now()
);

create index if not exists transactions_member_date_idx on public.transactions(member_id, occurred_on desc);
create index if not exists goals_member_idx on public.savings_goals(member_id);

create or replace function public.is_sama_nafa_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin' and p.status = 'active'
  );
$$;
revoke all on function public.is_sama_nafa_admin() from public;
grant execute on function public.is_sama_nafa_admin() to authenticated;

create or replace function public.is_sama_nafa_active_member()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.status = 'active'
  );
$$;
revoke all on function public.is_sama_nafa_active_member() from public;
grant execute on function public.is_sama_nafa_active_member() to authenticated;

create or replace function public.handle_new_sama_nafa_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role, status)
  values (
    new.id,
    coalesce(nullif(pg_catalog.btrim(new.raw_user_meta_data ->> 'display_name'), ''), 'Member'),
    'member', 'active'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_sama_nafa on auth.users;
create trigger on_auth_user_created_sama_nafa
after insert on auth.users
for each row execute function public.handle_new_sama_nafa_user();

alter table public.profiles enable row level security;
alter table public.transactions enable row level security;
alter table public.savings_goals enable row level security;

revoke all on public.profiles from anon, authenticated;
revoke all on public.transactions from anon, authenticated;
revoke all on public.savings_goals from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant select, insert on public.transactions to authenticated;
grant select, insert, update, delete on public.savings_goals to authenticated;

drop policy if exists "profile_self_or_admin_read" on public.profiles;
create policy "profile_self_or_admin_read" on public.profiles
for select to authenticated
using (id = (select auth.uid()) or (select public.is_sama_nafa_admin()));

drop policy if exists "profile_self_name_update" on public.profiles;
create policy "profile_self_name_update" on public.profiles
for update to authenticated
using (id = (select auth.uid()) and status = 'active')
with check (id = (select auth.uid()) and status = 'active');

drop policy if exists "transactions_self_or_admin_read" on public.transactions;
create policy "transactions_self_or_admin_read" on public.transactions
for select to authenticated
using (
  (member_id = (select auth.uid()) and (select public.is_sama_nafa_active_member()))
  or (select public.is_sama_nafa_admin())
);

drop policy if exists "transactions_self_or_admin_insert" on public.transactions;
create policy "transactions_self_or_admin_insert" on public.transactions
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (select public.is_sama_nafa_active_member())
  and (
    member_id = (select auth.uid())
    or (select public.is_sama_nafa_admin())
  )
);

drop policy if exists "goals_self_or_admin_read" on public.savings_goals;
create policy "goals_self_or_admin_read" on public.savings_goals
for select to authenticated
using (
  (member_id = (select auth.uid()) and (select public.is_sama_nafa_active_member()))
  or (select public.is_sama_nafa_admin())
);

drop policy if exists "goals_self_insert" on public.savings_goals;
create policy "goals_self_insert" on public.savings_goals
for insert to authenticated
with check (
  member_id = (select auth.uid())
  and (select public.is_sama_nafa_active_member())
);

drop policy if exists "goals_self_update" on public.savings_goals;
create policy "goals_self_update" on public.savings_goals
for update to authenticated
using (member_id = (select auth.uid()) and (select public.is_sama_nafa_active_member()))
with check (member_id = (select auth.uid()) and (select public.is_sama_nafa_active_member()));

drop policy if exists "goals_self_delete" on public.savings_goals;
create policy "goals_self_delete" on public.savings_goals
for delete to authenticated
using (member_id = (select auth.uid()) and (select public.is_sama_nafa_active_member()));

-- Database-side transaction validation prevents API clients bypassing browser checks.
-- Lock the profile row so two concurrent withdrawals for one member serialize.
create or replace function public.validate_sama_nafa_transaction()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  member_status text;
  current_balance numeric;
begin
  select p.status into member_status
  from public.profiles p
  where p.id = new.member_id
  for update;

  if member_status is distinct from 'active' then
    raise exception 'This member account is not active.';
  end if;

  if new.created_by is distinct from (select auth.uid()) then
    raise exception 'created_by must match the signed-in user.';
  end if;

  select coalesce(sum(case when t.kind = 'deposit' then t.amount_xof else -t.amount_xof end), 0)
  into current_balance
  from public.transactions t
  where t.member_id = new.member_id;

  if new.kind = 'withdrawal' and new.amount_xof > current_balance then
    raise exception 'Withdrawal exceeds the recorded savings balance.';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_sama_nafa_transaction_before_insert on public.transactions;
create trigger validate_sama_nafa_transaction_before_insert
before insert on public.transactions
for each row execute function public.validate_sama_nafa_transaction();

-- Admin-only status management. Members cannot promote themselves or change status directly.
create or replace function public.set_sama_nafa_member_status(target_member_id uuid, new_status text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not (select public.is_sama_nafa_admin()) then
    raise exception 'Only an active administrator can change member status.';
  end if;
  if new_status not in ('active', 'suspended') then
    raise exception 'Status must be active or suspended.';
  end if;
  if target_member_id = (select auth.uid()) then
    raise exception 'Administrators cannot change their own status here.';
  end if;
  update public.profiles
  set status = new_status
  where id = target_member_id and role = 'member';
  if not found then
    raise exception 'Member account not found.';
  end if;
end;
$$;
revoke all on function public.set_sama_nafa_member_status(uuid, text) from public;
grant execute on function public.set_sama_nafa_member_status(uuid, text) to authenticated;

-- Transactions are append-only: no client UPDATE or DELETE grants.
-- First admin setup must be performed manually after creating the admin's Auth user:
-- update public.profiles p set role = 'admin'
-- from auth.users u where p.id = u.id and u.email = 'YOUR_ADMIN_EMAIL';
-- Never set admin role from client input or user metadata.
