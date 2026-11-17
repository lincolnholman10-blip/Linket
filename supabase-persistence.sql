-- Linket persistent game data
-- Run this entire file in Supabase SQL Editor after deploying the matching index.html.

CREATE OR REPLACE FUNCTION public.linket_answer_question(
  p_question integer,
  p_answer integer
)
RETURNS TABLE(correct boolean, tokens bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_correct_answer integer;
  v_tokens bigint;
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  v_correct_answer := CASE p_question
    WHEN 0 THEN 2
    WHEN 1 THEN 1
    WHEN 2 THEN 2
    WHEN 3 THEN 2
    ELSE NULL
  END;

  IF v_correct_answer IS NULL THEN
    RAISE EXCEPTION 'Invalid question.';
  END IF;

  IF p_answer = v_correct_answer THEN
    UPDATE public.profiles AS p
      SET tokens = p.tokens + 25
      WHERE p.id = v_user_id
      RETURNING p.tokens INTO v_tokens;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Player profile not found.';
    END IF;
    RETURN QUERY SELECT true, v_tokens;
  ELSE
    SELECT p.tokens INTO v_tokens
      FROM public.profiles p
      WHERE p.id = v_user_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Player profile not found.';
    END IF;
    RETURN QUERY SELECT false, v_tokens;
  END IF;
END;
$$;

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

  -- Weighted rarity chances within each pack: Common 70%, Rare 20%,
  -- Epic 7%, Legendary 2.5%, Mythical 0.5%.
  SELECT pool.collectible INTO v_collectible
  FROM (VALUES
    (50, 'Happy Turtle', 700), (50, 'Bouncy Bunny', 700),
    (50, 'Robot Buddy', 200), (50, 'Frost Wolf', 70),
    (50, 'Golden Owl', 25), (50, 'Starwing', 5),
    (100, 'Tiny Bee', 700), (100, 'Bouncy Bunny', 700),
    (100, 'Robot Buddy', 200), (100, 'Crystal Cat', 25),
    (100, 'Lumi Fox', 5),
    (150, 'Robot Buddy', 200), (150, 'Frost Wolf', 70),
    (150, 'Crystal Cat', 25), (150, 'Galaxy Dragon', 5),
    (150, 'Starwing', 5)
  ) AS pool(pack_cost, collectible, weight)
  WHERE pool.pack_cost = p_cost
  ORDER BY -ln(greatest(random(), 0.0000000001)) / pool.weight
  LIMIT 1;

  IF v_collectible IS NULL THEN RAISE EXCEPTION 'No collectibles are configured for this pack.'; END IF;
  INSERT INTO public.owned_collectibles(user_id, collectible_id, quantity)
  VALUES (v_user_id, v_collectible, 1)
  ON CONFLICT (user_id, collectible_id)
  DO UPDATE SET quantity = public.owned_collectibles.quantity + 1;
  RETURN QUERY SELECT v_collectible, v_tokens;
END;
$linket$;
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
    ('Happy Turtle'), ('Tiny Bee'), ('Bouncy Bunny'),
    ('Robot Buddy'), ('Frost Wolf'), ('Golden Owl'),
    ('Crystal Cat'), ('Lumi Fox'), ('Galaxy Dragon'), ('Starwing')
  ) AS catalog(collectible)
  ON CONFLICT (user_id, collectible_id) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_owner_restore_tokens()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_tokens bigint;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  UPDATE public.profiles
    SET tokens = 1000000
    WHERE id = v_user_id AND is_owner = true
    RETURNING profiles.tokens INTO v_tokens;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  RETURN v_tokens;
END;
$$;

REVOKE ALL ON FUNCTION public.linket_answer_question(integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_open_pack(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_owner_unlock_all() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_owner_restore_tokens() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.linket_answer_question(integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_open_pack(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_owner_unlock_all() TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_owner_restore_tokens() TO authenticated;


-- Live multiplayer room lobby
CREATE TABLE IF NOT EXISTS public.linket_live_rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_code text NOT NULL UNIQUE CHECK (room_code ~ '^[A-Z0-9]{6}$'),
  host_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'playing', 'finished')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.linket_live_room_players (
  room_id uuid NOT NULL REFERENCES public.linket_live_rooms(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  username text NOT NULL,
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, user_id)
);

ALTER TABLE public.linket_live_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linket_live_room_players ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Signed-in users can view waiting Linket rooms" ON public.linket_live_rooms;
CREATE POLICY "Signed-in users can view waiting Linket rooms"
  ON public.linket_live_rooms FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Players can create their own Linket rooms" ON public.linket_live_rooms;
CREATE POLICY "Players can create their own Linket rooms"
  ON public.linket_live_rooms FOR INSERT TO authenticated
  WITH CHECK (host_user_id = auth.uid());

DROP POLICY IF EXISTS "Signed-in users can view Linket room players" ON public.linket_live_room_players;
CREATE POLICY "Signed-in users can view Linket room players"
  ON public.linket_live_room_players FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Players can join Linket rooms as themselves" ON public.linket_live_room_players;
CREATE POLICY "Players can join Linket rooms as themselves"
  ON public.linket_live_room_players FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND EXISTS (
    SELECT 1 FROM public.linket_live_rooms r WHERE r.id = room_id
  ));

DROP POLICY IF EXISTS "Players can rejoin Linket rooms as themselves" ON public.linket_live_room_players;
CREATE POLICY "Players can rejoin Linket rooms as themselves"
  ON public.linket_live_room_players FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

GRANT SELECT, INSERT ON public.linket_live_rooms TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.linket_live_room_players TO authenticated;

DROP POLICY IF EXISTS "Players can leave Linket rooms" ON public.linket_live_room_players;
CREATE POLICY "Players can leave Linket rooms"
  ON public.linket_live_room_players FOR DELETE TO authenticated
  USING (user_id = auth.uid());
GRANT DELETE ON public.linket_live_room_players TO authenticated;
