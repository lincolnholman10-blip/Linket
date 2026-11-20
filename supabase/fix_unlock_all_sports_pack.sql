-- Add Sports Pack collectibles to the Owner Dashboard "Unlock every collectible" action.
-- Owner God is intentionally excluded because it is a separate secret, permanent collectible.

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
    ('Golden Retriever'), ('Cosmic Wolf'),
    ('Rookie Hooper'), ('Goal Getter'), ('Court Captain'),
    ('Grand Slam Star'), ('Championship MVP'), ('Mason Plumlee')
  ) AS catalog(collectible)
  ON CONFLICT (user_id, collectible_id) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.linket_owner_unlock_all() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.linket_owner_unlock_all() TO authenticated;
NOTIFY pgrst, 'reload schema';
