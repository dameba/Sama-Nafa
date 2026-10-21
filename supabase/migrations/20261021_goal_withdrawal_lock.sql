-- Optional date-based savings lock for Sama Nafa goals.
-- Apply this migration in the Supabase SQL Editor before using the new UI.
-- A locked goal's assigned deposits are reserved until locked_until; withdrawals
-- that would consume those reserved funds are rejected by the database.

ALTER TABLE public.savings_goals
ADD COLUMN IF NOT EXISTS locked_until date;

CREATE OR REPLACE FUNCTION public.validate_sama_nafa_transaction_goal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  goal_owner uuid;
  available_xof numeric;
BEGIN
  IF NEW.goal_id IS NOT NULL THEN
    IF NEW.kind <> 'deposit' THEN
      RAISE EXCEPTION 'Only deposits can be linked to a savings goal.';
    END IF;

    SELECT g.member_id
    INTO goal_owner
    FROM public.savings_goals AS g
    WHERE g.id = NEW.goal_id;

    IF goal_owner IS NULL OR goal_owner <> NEW.member_id THEN
      RAISE EXCEPTION 'Choose one of your own savings goals.';
    END IF;
  END IF;

  IF NEW.kind = 'withdrawal' THEN
    SELECT
      COALESCE(SUM(CASE WHEN t.kind = 'deposit' THEN t.amount_xof ELSE -t.amount_xof END), 0)
      - COALESCE((
        SELECT SUM(td.amount_xof)
        FROM public.transactions AS td
        JOIN public.savings_goals AS gd ON gd.id = td.goal_id
        WHERE td.member_id = NEW.member_id
          AND td.kind = 'deposit'
          AND gd.locked_until > CURRENT_DATE
      ), 0)
    INTO available_xof
    FROM public.transactions AS t
    WHERE t.member_id = NEW.member_id;

    IF NEW.amount_xof > available_xof THEN
      RAISE EXCEPTION 'This withdrawal would use savings locked until a goal unlock date. Available to withdraw: % FCFA.', GREATEST(available_xof, 0);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- The existing validate_sama_nafa_transaction_goal trigger already calls this
-- function, so replacing the function above updates its behavior safely.

-- While a lock is active, it cannot be removed or shortened.
CREATE OR REPLACE FUNCTION public.protect_sama_nafa_goal_lock()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.locked_until IS NOT NULL
     AND OLD.locked_until > CURRENT_DATE
     AND (NEW.locked_until IS NULL OR NEW.locked_until < OLD.locked_until) THEN
    RAISE EXCEPTION 'An active savings lock cannot be removed or shortened before its unlock date.';
  END IF;

  IF NEW.locked_until IS NOT NULL AND NEW.locked_until < CURRENT_DATE THEN
    RAISE EXCEPTION 'Choose today or a future date for the savings lock.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_sama_nafa_goal_lock
BEFORE INSERT OR UPDATE OF locked_until ON public.savings_goals
FOR EACH ROW
EXECUTE FUNCTION public.protect_sama_nafa_goal_lock();
