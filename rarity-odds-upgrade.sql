-- Linket rarity odds upgrade
-- Run this entire script once in Supabase Dashboard -> SQL Editor.
-- Existing collectible pools and pack prices are preserved.

CREATE OR REPLACE FUNCTION public.linket_open_pack(p_cost integer)
RETURNS TABLE(collectible_id text, tokens bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $linket$
#variable_conflict use_column
DECLARE
  v_user_id uuid := auth.uid();
  v_tokens bigint;
  v_is_owner boolean;
  v_collectible text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_cost NOT IN (50, 100, 150) THEN RAISE EXCEPTION 'Invalid pack price.'; END IF;

  SELECT p.tokens, p.is_owner INTO v_tokens, v_is_owner
  FROM public.profiles p WHERE p.id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player profile not found.'; END IF;

  IF NOT COALESCE(v_is_owner, false) THEN
    IF v_tokens < p_cost THEN RAISE EXCEPTION 'Not enough tokens.'; END IF;
    UPDATE public.profiles p SET tokens = p.tokens - p_cost
    WHERE p.id = v_user_id RETURNING p.tokens INTO v_tokens;
  END IF;

  -- Per-pack weighted odds:
  -- Christmas: Legendary about 2.02%, Mythical about 0.071%.
  -- Rainbow: Legendary about 2.17%, Mythical about 0.011%.
  -- Galaxy: Legendary about 2.17%, Mythical about 0.011%.
  -- Each pack keeps its original eligible collectible pool.
  SELECT pool.collectible INTO v_collectible
  FROM (VALUES
    (50, 'Happy Turtle', 35000),
    (50, 'Bouncy Bunny', 35000),
    (50, 'Robot Buddy', 20000),
    (50, 'Frost Wolf', 7000),
    (50, 'Golden Owl', 2000),
    (50, 'Starwing', 70),

    (100, 'Tiny Bee', 35000),
    (100, 'Bouncy Bunny', 35000),
    (100, 'Robot Buddy', 20000),
    (100, 'Crystal Cat', 2000),
    (100, 'Lumi Fox', 10),

    (150, 'Robot Buddy', 70000),
    (150, 'Frost Wolf', 20000),
    (150, 'Crystal Cat', 2000),
    (150, 'Galaxy Dragon', 5),
    (150, 'Starwing', 5)
  ) AS pool(pack_cost, collectible, weight)
  WHERE pool.pack_cost = p_cost
  ORDER BY -ln(greatest(random(), 0.0000000001)) / pool.weight
  LIMIT 1;

  IF v_collectible IS NULL THEN
    RAISE EXCEPTION 'No collectibles are configured for this pack.';
  END IF;

  INSERT INTO public.owned_collectibles(user_id, collectible_id, quantity)
  VALUES (v_user_id, v_collectible, 1)
  ON CONFLICT (user_id, collectible_id)
  DO UPDATE SET quantity = public.owned_collectibles.quantity + 1;

  RETURN QUERY SELECT v_collectible, v_tokens;
END;
$linket$;
