-- Allow the Mythical Sports Pack collectible Mason Plumlee to be sold.
-- Keep all unlisted collectibles (including Owner God and Da Bears) protected.
CREATE OR REPLACE FUNCTION public.linket_sell_collectibles(p_collectible_id text, p_quantity integer)
 RETURNS TABLE(tokens_earned bigint, new_balance bigint, remaining_quantity integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_owned integer;
  v_price bigint;
  v_earned bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Please sign in before selling collectibles.';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 THEN
    RAISE EXCEPTION 'Choose at least one collectible to sell.';
  END IF;

  v_price := CASE p_collectible_id
    WHEN 'Happy Turtle' THEN 5
    WHEN 'Tiny Bee' THEN 5
    WHEN 'Bouncy Bunny' THEN 5
    WHEN 'Robot Buddy' THEN 15
    WHEN 'Frost Wolf' THEN 30
    WHEN 'Golden Owl' THEN 50
    WHEN 'Crystal Cat' THEN 50
    WHEN 'Lumi Fox' THEN 100
    WHEN 'Galaxy Dragon' THEN 100
    WHEN 'Starwing' THEN 100
    WHEN 'Mason Plumlee' THEN 100
    ELSE NULL
  END;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'That collectible cannot be sold.';
  END IF;

  SELECT oc.quantity
  INTO v_owned
  FROM public.owned_collectibles oc
  WHERE oc.user_id = v_user
    AND oc.collectible_id = p_collectible_id
  FOR UPDATE;

  IF NOT FOUND OR v_owned < p_quantity THEN
    RAISE EXCEPTION 'You do not own that many copies of this collectible.';
  END IF;

  v_earned := v_price * p_quantity;

  IF v_owned = p_quantity THEN
    DELETE FROM public.owned_collectibles
    WHERE user_id = v_user AND collectible_id = p_collectible_id;
    remaining_quantity := 0;
  ELSE
    UPDATE public.owned_collectibles
    SET quantity = quantity - p_quantity
    WHERE user_id = v_user AND collectible_id = p_collectible_id
    RETURNING quantity INTO remaining_quantity;
  END IF;

  UPDATE public.profiles
  SET tokens = tokens + v_earned
  WHERE id = v_user
  RETURNING tokens INTO new_balance;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player profile not found.';
  END IF;

  tokens_earned := v_earned;
  RETURN NEXT;
END;
$function$;

NOTIFY pgrst, 'reload schema';
