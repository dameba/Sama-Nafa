-- Sama Nafa secure multi-member foundation
-- Run this in the Supabase SQL Editor before connecting the app.
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

-- Security-definer helper prevents recursive profile policies.
create or replace function public.is_sama_nafa_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin'
      and p.status = 'active'
  );
$$;
revoke all on function public.is_sama_nafa_admin() from public;
grant execute on function public.is_sama_nafa_admin() to authenticated;

-- New invited accounts automatically get member role; never accept a role from metadata.
create or replace function public.handle_new_sama_nafa_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role, status)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Member'),
    'member',
    'active'
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

-- Remove broad defaults, then grant only the client operations needed.
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
  (member_id = (select auth.uid()) and exists (
    select 1 from public.profiles p where p.id = (select auth.uid()) and p.status = 'active'
  ))
  or (select public.is_sama_nafa_admin())
);

drop policy if exists "transactions_self_or_admin_insert" on public.transactions;
create policy "transactions_self_or_admin_insert" on public.transactions
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (
    (member_id = (select auth.uid()) and exists (
      select 1 from public.profiles p where p.id = (select auth.uid()) and p.status = 'active'
    ))
    or (select public.is_sama_nafa_admin())
  )
);

-- Transactions are append-only for members; use an auditable correction workflow for adjustments.
-- No client UPDATE or DELETE grants are given to authenticated users.

drop policy if exists "goals_self_or_admin_read" on public.savings_goals;
create policy "goals_self_or_admin_read" on public.savings_goals
for select to authenticated
using (member_id = (select auth.uid()) or (select public.is_sama_nafa_admin()));

drop policy if exists "goals_self_insert" on public.savings_goals;
create policy "goals_self_insert" on public.savings_goals
for insert to authenticated
with check (
  member_id = (select auth.uid())
  and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.status = 'active')
);

drop policy if exists "goals_self_update" on public.savings_goals;
create policy "goals_self_update" on public.savings_goals
for update to authenticated
using (member_id = (select auth.uid()))
with check (member_id = (select auth.uid()));

drop policy if exists "goals_self_delete" on public.savings_goals;
create policy "goals_self_delete" on public.savings_goals
for delete to authenticated
using (member_id = (select auth.uid()));

-- Initial admin setup:
-- 1. Create your own user in Supabase Auth.
-- 2. Run the following separately, replacing the email with the exact admin email:
-- update public.profiles p set role = 'admin'
-- from auth.users u where p.id = u.id and u.email = 'YOUR_ADMIN_EMAIL';
-- Never let a public signup or client request set role='admin'.
