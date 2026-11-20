-- Sports Pack: 200 tokens. Mason Plumlee is a Mythical collectible
-- with an exact 0.005% chance (5 weight units out of 100,000).
CREATE OR REPLACE FUNCTION public.linket_open_pack(p_cost integer)
 RETURNS TABLE(collectible_id text, tokens bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id uuid := auth.uid();
  v_tokens bigint;
  v_is_owner boolean;
  v_collectible text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_cost NOT IN (50, 75, 100, 125, 150, 175, 200) THEN
    RAISE EXCEPTION 'Invalid pack price.';
  END IF;

  SELECT p.tokens, p.is_owner INTO v_tokens, v_is_owner
  FROM public.profiles p WHERE p.id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player profile not found.'; END IF;

  -- All accounts, including the owner account, pay the listed pack price.
  IF v_tokens < p_cost THEN RAISE EXCEPTION 'Not enough tokens.'; END IF;
  UPDATE public.profiles p SET tokens = p.tokens - p_cost
  WHERE p.id = v_user_id RETURNING p.tokens INTO v_tokens;

  SELECT pool.collectible INTO v_collectible
  FROM (VALUES
    (50, 'Happy Turtle', 35000), (50, 'Bouncy Bunny', 35000),
    (50, 'Robot Buddy', 20000), (50, 'Frost Wolf', 7000),
    (50, 'Golden Owl', 2000), (50, 'Starwing', 70),
    (100, 'Tiny Bee', 35000), (100, 'Bouncy Bunny', 35000),
    (100, 'Robot Buddy', 20000), (100, 'Crystal Cat', 2000),
    (100, 'Lumi Fox', 10),
    (150, 'Robot Buddy', 70000), (150, 'Frost Wolf', 20000),
    (150, 'Crystal Cat', 2000), (150, 'Galaxy Dragon', 5),
    (150, 'Starwing', 5),

    (75, 'Seashell Snail', 35000), (75, 'Surfer Seal', 35000),
    (75, 'Crab Pal', 20000), (75, 'Coral Turtle', 7000),
    (75, 'Pearl Dolphin', 2950), (75, 'Tidal Phoenix', 50),

    (125, 'Moon Moth', 35000), (125, 'Astro Pup', 35000),
    (125, 'Comet Cat', 20000), (125, 'Nebula Fox', 7000),
    (125, 'Solar Dragon', 2950), (125, 'Void Unicorn', 50),

    (175, 'Puppy Pal', 35000), (175, 'Corgi Buddy', 35000),
    (175, 'Dalmatian Dash', 20000), (175, 'Shiba Star', 7000),
    (175, 'Golden Retriever', 2950), (175, 'Cosmic Wolf', 50),

    -- Sports Pack: 40% / 30% / 20% / 7% / 2.995% / 0.005%.
    (200, 'Rookie Hooper', 40000), (200, 'Goal Getter', 30000),
    (200, 'Court Captain', 20000), (200, 'Grand Slam Star', 7000),
    (200, 'Championship MVP', 2995), (200, 'Mason Plumlee', 5)
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
$function$;

GRANT EXECUTE ON FUNCTION public.linket_open_pack(integer) TO authenticated;
NOTIFY pgrst, 'reload schema';
