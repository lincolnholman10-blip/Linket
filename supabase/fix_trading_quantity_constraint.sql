-- Fix trade acceptance with owned_collectibles.quantity > 0.
-- The old function updated a fully traded-away row to quantity 0 before deleting it.
-- This version deletes fully transferred rows directly and only subtracts when a positive remainder remains.

CREATE OR REPLACE FUNCTION public.linket_trade_respond(p_trade_id uuid, p_accept boolean)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t public.linket_trades%rowtype;
  it record;
  v_have integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Please sign in.';
  END IF;

  SELECT * INTO t
  FROM public.linket_trades
  WHERE id = p_trade_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trade not found.';
  END IF;
  IF t.recipient_id <> auth.uid() THEN
    RAISE EXCEPTION 'Only the recipient can respond to this trade.';
  END IF;
  IF t.status <> 'pending' THEN
    RAISE EXCEPTION 'This trade is no longer pending.';
  END IF;

  IF NOT p_accept THEN
    UPDATE public.linket_trades
    SET status = 'declined'
    WHERE id = p_trade_id;
    RETURN 'declined';
  END IF;

  -- Lock and validate all offered inventory before making any changes.
  FOR it IN
    SELECT *
    FROM public.linket_trade_items
    WHERE trade_id = p_trade_id
    ORDER BY owner_id, collectible_id
  LOOP
    SELECT quantity INTO v_have
    FROM public.owned_collectibles
    WHERE user_id = it.owner_id
      AND collectible_id = it.collectible_id
    FOR UPDATE;

    IF COALESCE(v_have, 0) < it.quantity THEN
      RAISE EXCEPTION 'A player no longer owns enough %; the trade was not completed.', it.collectible_id;
    END IF;
  END LOOP;

  -- Remove outgoing copies without ever writing quantity 0.
  FOR it IN
    SELECT *
    FROM public.linket_trade_items
    WHERE trade_id = p_trade_id
    ORDER BY owner_id, collectible_id
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.owned_collectibles
      WHERE user_id = it.owner_id
        AND collectible_id = it.collectible_id
        AND quantity = it.quantity
    ) THEN
      DELETE FROM public.owned_collectibles
      WHERE user_id = it.owner_id
        AND collectible_id = it.collectible_id
        AND quantity = it.quantity;
    ELSE
      UPDATE public.owned_collectibles
      SET quantity = quantity - it.quantity
      WHERE user_id = it.owner_id
        AND collectible_id = it.collectible_id;
    END IF;
  END LOOP;

  -- Add the incoming copies to each player's inventory.
  FOR it IN
    SELECT *
    FROM public.linket_trade_items
    WHERE trade_id = p_trade_id
  LOOP
    INSERT INTO public.owned_collectibles(user_id, collectible_id, quantity)
    VALUES (
      CASE WHEN it.owner_id = t.sender_id THEN t.recipient_id ELSE t.sender_id END,
      it.collectible_id,
      it.quantity
    )
    ON CONFLICT (user_id, collectible_id)
    DO UPDATE
      SET quantity = public.owned_collectibles.quantity + EXCLUDED.quantity;
  END LOOP;

  UPDATE public.linket_trades
  SET status = 'accepted',
      recipient_confirmed = true,
      completed_at = now()
  WHERE id = p_trade_id;

  RETURN 'accepted';
END;
$$;

REVOKE ALL ON FUNCTION public.linket_trade_respond(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_trade_respond(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.linket_trade_respond(uuid, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
