-- PROPOSED migration: member-to-member internal transfers for Sama Nafa.
-- This file is prepared on the development branch only. Do NOT run it until reviewed/approved.
-- Transfers are internal savings records, not real money movement.

CREATE TABLE IF NOT EXISTS public.member_transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  recipient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount_xof bigint NOT NULL CHECK (amount_xof > 0),
  note text NOT NULL DEFAULT '' CHECK (char_length(note) <= 240),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (sender_id <> recipient_id)
);

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS transfer_id uuid
  REFERENCES public.member_transfers(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS member_transfers_sender_created_idx
  ON public.member_transfers(sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS member_transfers_recipient_created_idx
  ON public.member_transfers(recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS transactions_transfer_id_idx
  ON public.transactions(transfer_id);

ALTER TABLE public.member_transfers ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.member_transfers FROM anon, authenticated;
GRANT SELECT ON public.member_transfers TO authenticated;

DROP POLICY IF EXISTS member_transfers_participant_read ON public.member_transfers;
CREATE POLICY member_transfers_participant_read
ON public.member_transfers
FOR SELECT TO authenticated
USING (
  sender_id = (SELECT auth.uid())
  OR recipient_id = (SELECT auth.uid())
  OR (SELECT public.is_sama_nafa_admin())
);

CREATE OR REPLACE FUNCTION public.create_sama_nafa_member_transfer(
  p_recipient_id uuid,
  p_amount_xof bigint,
  p_note text DEFAULT ''
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_sender_id uuid := auth.uid();
  v_sender_status text;
  v_recipient_status text;
  v_balance numeric;
  v_transfer_id uuid;
  v_note text := coalesce(trim(p_note), '');
BEGIN
  IF v_sender_id IS NULL THEN
    RAISE EXCEPTION 'Sign in to make a transfer.';
  END IF;

  IF p_recipient_id IS NULL OR p_recipient_id = v_sender_id THEN
    RAISE EXCEPTION 'Choose another registered member.';
  END IF;

  IF p_amount_xof IS NULL OR p_amount_xof <= 0 THEN
    RAISE EXCEPTION 'Enter a positive transfer amount.';
  END IF;

  IF p_amount_xof > 9007199254740991 THEN
    RAISE EXCEPTION 'Transfer amount is too large.';
  END IF;

  IF char_length(v_note) > 240 THEN
    RAISE EXCEPTION 'Transfer note must be 240 characters or fewer.';
  END IF;

  -- Lock both profiles in a stable order to serialize concurrent transfers
  -- involving either participant and prevent balance races.
  PERFORM 1
  FROM public.profiles p
  WHERE p.id IN (v_sender_id, p_recipient_id)
  ORDER BY p.id
  FOR UPDATE;

  SELECT status INTO v_sender_status
  FROM public.profiles WHERE id = v_sender_id;

  SELECT status INTO v_recipient_status
  FROM public.profiles WHERE id = p_recipient_id;

  IF v_sender_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Only active members can send transfers.';
  END IF;
  IF v_recipient_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'The recipient must be an active Sama Nafa member.';
  END IF;

  SELECT coalesce(sum(
    CASE WHEN t.kind = 'deposit' THEN t.amount_xof ELSE -t.amount_xof END
  ), 0)
  INTO v_balance
  FROM public.transactions t
  WHERE t.member_id = v_sender_id;

  IF p_amount_xof > v_balance THEN
    RAISE EXCEPTION 'Insufficient recorded balance.';
  END IF;

  -- The existing withdrawal trigger enforces locked-goal reserves as well.
  INSERT INTO public.member_transfers(sender_id, recipient_id, amount_xof, note)
  VALUES (v_sender_id, p_recipient_id, p_amount_xof, v_note)
  RETURNING id INTO v_transfer_id;

  INSERT INTO public.transactions
    (member_id, created_by, kind, amount_xof, note, occurred_on, transfer_id, goal_id)
  VALUES
    (v_sender_id, v_sender_id, 'withdrawal', p_amount_xof,
     CASE WHEN v_note = '' THEN 'Transfer to member' ELSE 'Transfer to member: ' || v_note END,
     current_date, v_transfer_id, NULL);

  INSERT INTO public.transactions
    (member_id, created_by, kind, amount_xof, note, occurred_on, transfer_id, goal_id)
  VALUES
    (p_recipient_id, v_sender_id, 'deposit', p_amount_xof,
     CASE WHEN v_note = '' THEN 'Transfer from member' ELSE 'Transfer from member: ' || v_note END,
     current_date, v_transfer_id, NULL);

  RETURN v_transfer_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_sama_nafa_member_transfer(uuid, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_sama_nafa_member_transfer(uuid, bigint, text) TO authenticated;

COMMENT ON TABLE public.member_transfers IS
'Internal Sama Nafa savings-record transfers only; does not move real money.';
