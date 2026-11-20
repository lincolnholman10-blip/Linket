-- Allow the Linket owner to remove any collectible, including the secret Owner God.
-- Removal requires a reason and queues a one-time notification for the affected player.

CREATE OR REPLACE FUNCTION public.linket_owner_remove_collectible(
  p_user_id uuid,
  p_collectible_id text,
  p_quantity integer,
  p_reason text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_reason text := trim(coalesce(p_reason, ''));
  v_remaining integer;
  v_owned integer;
  v_name text;
BEGIN
  IF v_actor IS NULL OR NOT public.linket_owner_dashboard_is_owner() THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  IF p_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p WHERE p.id = p_user_id
  ) THEN
    RAISE EXCEPTION 'Choose a valid player.';
  END IF;

  IF p_collectible_id IS NULL OR length(trim(p_collectible_id)) = 0 THEN
    RAISE EXCEPTION 'Choose a collectible.';
  END IF;

  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 1000 THEN
    RAISE EXCEPTION 'Quantity must be between 1 and 1000.';
  END IF;

  IF length(v_reason) = 0 THEN
    RAISE EXCEPTION 'A reason is required when removing a collectible.';
  END IF;
  IF length(v_reason) > 300 THEN
    RAISE EXCEPTION 'The reason must be 300 characters or fewer.';
  END IF;

  IF p_collectible_id = '__OWNER_GOD__' THEN
    SELECT h.quantity INTO v_owned
    FROM public.linket_owner_god_holders h
    WHERE h.user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'This player does not own Owner God.';
    END IF;

    IF v_owned < p_quantity THEN
      RAISE EXCEPTION 'This player only owns % Owner God. Reduce the quantity.', v_owned;
    END IF;

    v_remaining := v_owned - p_quantity;
    IF v_remaining = 0 THEN
      DELETE FROM public.linket_owner_god_holders WHERE user_id = p_user_id;
    ELSE
      UPDATE public.linket_owner_god_holders
      SET quantity = v_remaining
      WHERE user_id = p_user_id;
    END IF;
    v_name := 'Owner God';
  ELSE
    SELECT oc.quantity INTO v_owned
    FROM public.owned_collectibles oc
    WHERE oc.user_id = p_user_id
      AND oc.collectible_id = p_collectible_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'This player does not own that collectible.';
    END IF;

    IF v_owned < p_quantity THEN
      RAISE EXCEPTION 'This player only owns % of that collectible. Reduce the quantity.', v_owned;
    END IF;

    v_remaining := v_owned - p_quantity;
    IF v_remaining = 0 THEN
      DELETE FROM public.owned_collectibles
      WHERE user_id = p_user_id AND collectible_id = p_collectible_id;
    ELSE
      UPDATE public.owned_collectibles
      SET quantity = v_remaining
      WHERE user_id = p_user_id AND collectible_id = p_collectible_id;
    END IF;
    v_name := p_collectible_id;
  END IF;

  -- Same next-login notification behavior as owner token deductions.
  IF p_user_id <> v_actor THEN
    INSERT INTO public.linket_player_notifications(user_id, title, message)
    VALUES (
      p_user_id,
      '⚠️ Collectible update from Linket',
      'The Linket owner removed ' || p_quantity || ' × ' || v_name ||
      ' from your collection. Reason: ' || v_reason
    );
  END IF;

  RETURN v_remaining;
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_owner_remove_collectible(uuid, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.linket_owner_remove_collectible(uuid, text, integer, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
