-- Linket themed mystery packs: Beach, Space, and Dog.
-- Run this entire script in Supabase SQL Editor after the matching website update.

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
  IF p_cost NOT IN (50, 75, 100, 125, 150, 175) THEN
    RAISE EXCEPTION 'Invalid pack price.';
  END IF;

  SELECT p.tokens, p.is_owner INTO v_tokens, v_is_owner
  FROM public.profiles p WHERE p.id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player profile not found.'; END IF;

  -- All accounts, including the owner account, pay the listed pack price.
  IF v_tokens < p_cost THEN RAISE EXCEPTION 'Not enough tokens.'; END IF;
  UPDATE public.profiles p SET tokens = p.tokens - p_cost
  WHERE p.id = v_user_id RETURNING p.tokens INTO v_tokens;

  -- Each new themed pack has 35% / 35% / 20% / 7% / 2.95% / 0.05% odds.
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
    (175, 'Golden Retriever', 2950), (175, 'Cosmic Wolf', 50)
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

-- Make all new collectibles available to the owner's unlock-all button.
CREATE OR REPLACE FUNCTION public.linket_owner_unlock_all()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_count integer;
BEGIN
  IF v_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_user_id AND p.is_owner = true
  ) THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  INSERT INTO public.owned_collectibles(user_id, collectible_id, quantity)
  SELECT v_user_id, catalog.collectible, 1
  FROM (VALUES
    ('Happy Turtle'), ('Tiny Bee'), ('Bouncy Bunny'), ('Robot Buddy'),
    ('Frost Wolf'), ('Golden Owl'), ('Crystal Cat'), ('Lumi Fox'),
    ('Galaxy Dragon'), ('Starwing'),
    ('Seashell Snail'), ('Surfer Seal'), ('Crab Pal'), ('Coral Turtle'),
    ('Pearl Dolphin'), ('Tidal Phoenix'),
    ('Moon Moth'), ('Astro Pup'), ('Comet Cat'), ('Nebula Fox'),
    ('Solar Dragon'), ('Void Unicorn'),
    ('Puppy Pal'), ('Corgi Buddy'), ('Dalmatian Dash'), ('Shiba Star'),
    ('Golden Retriever'), ('Cosmic Wolf')
  ) AS catalog(collectible)
  ON CONFLICT (user_id, collectible_id) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.linket_open_pack(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_owner_unlock_all() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.linket_open_pack(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_owner_unlock_all() TO authenticated;
