-- Safe additive migration for goal-linked deposits.
-- Existing transactions remain unchanged with goal_id = NULL.
alter table public.transactions
  add column if not exists goal_id uuid
  references public.savings_goals(id) on delete set null;

create index if not exists transactions_goal_id_idx
  on public.transactions(goal_id);

-- A transaction may only contribute to a goal owned by the same member.
-- Withdrawals remain unlinked in this version; only deposits count toward goal progress.
create or replace function public.validate_sama_nafa_transaction_goal()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  goal_owner uuid;
begin
  if new.goal_id is null then
    return new;
  end if;

  if new.kind <> 'deposit' then
    raise exception 'Only deposits can be linked to a savings goal.';
  end if;

  select g.member_id into goal_owner
  from public.savings_goals g
  where g.id = new.goal_id;

  if goal_owner is null or goal_owner <> new.member_id then
    raise exception 'Choose one of your own savings goals.';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_sama_nafa_transaction_goal on public.transactions;
create trigger validate_sama_nafa_transaction_goal
before insert on public.transactions
for each row execute function public.validate_sama_nafa_transaction_goal();
