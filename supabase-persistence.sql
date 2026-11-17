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

 
-- Collectible avatars: a player may only equip a collectible they currently own.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_collectible text;

CREATE OR REPLACE FUNCTION public.linket_set_avatar(p_collectible_id text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF p_collectible_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.owned_collectibles oc
    WHERE oc.user_id = v_user_id
      AND oc.collectible_id = p_collectible_id
      AND oc.quantity > 0
  ) THEN
    RAISE EXCEPTION 'You can only choose a collectible you own.';
  END IF;

  UPDATE public.profiles
  SET avatar_collectible = p_collectible_id
  WHERE id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player profile not found.';
  END IF;

  RETURN p_collectible_id;
END;
$$;

REVOKE ALL ON FUNCTION public.linket_set_avatar(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.linket_set_avatar(text) TO authenticated;


-- Shared multiplayer Quiz Battle state and secure room actions.
ALTER TABLE public.linket_live_rooms
  ADD COLUMN IF NOT EXISTS game_mode text,
  ADD COLUMN IF NOT EXISTS current_question integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS question_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS scores jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS answers jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.linket_live_set_mode(p_room_id uuid,p_game_mode text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $
DECLARE
  v_room public.linket_live_rooms%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_game_mode NOT IN ('quiz_battle','speed_round','relaxed_round') THEN
    RAISE EXCEPTION 'Choose a valid multiplayer game mode.';
  END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room not found.'; END IF;
  IF v_room.host_user_id <> auth.uid() THEN RAISE EXCEPTION 'Only the host can choose the game mode.'; END IF;
  IF v_room.status <> 'waiting' THEN RAISE EXCEPTION 'The game has already started.'; END IF;
  UPDATE public.linket_live_rooms SET game_mode=p_game_mode WHERE id=p_room_id;
END;
$;

CREATE OR REPLACE FUNCTION public.linket_live_start_game(p_room_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room public.linket_live_rooms%ROWTYPE;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room not found.'; END IF;
  IF v_room.host_user_id <> auth.uid() THEN RAISE EXCEPTION 'Only the host can start the game.'; END IF;
  IF v_room.status <> 'waiting' THEN RAISE EXCEPTION 'This room has already started.'; END IF;
  IF COALESCE(v_room.game_mode,'quiz_battle') NOT IN ('quiz_battle','speed_round','relaxed_round') THEN
    RAISE EXCEPTION 'Choose a valid multiplayer game mode.';
  END IF;
  SELECT count(*) INTO v_count FROM public.linket_live_room_players WHERE room_id=p_room_id;
  IF v_count < 2 THEN RAISE EXCEPTION 'At least 2 players are needed to start.'; END IF;
  UPDATE public.linket_live_rooms
  SET status='playing', game_mode=COALESCE(game_mode,'quiz_battle'), current_question=0,
      question_started_at=now(), scores='{}'::jsonb, answers='{}'::jsonb
  WHERE id=p_room_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_live_submit_answer(p_room_id uuid,p_question integer,p_answer integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room public.linket_live_rooms%ROWTYPE;
  v_correct integer;
  v_user text := auth.uid()::text;
  v_scores jsonb;
  v_answers jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND OR v_room.status <> 'playing' THEN RAISE EXCEPTION 'This game is not active.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.linket_live_room_players WHERE room_id=p_room_id AND user_id=auth.uid()) THEN
    RAISE EXCEPTION 'You are not in this room.';
  END IF;
  IF p_question <> v_room.current_question OR p_question NOT BETWEEN 0 AND 4 THEN RAISE EXCEPTION 'That question is no longer active.'; END IF;
  IF p_answer NOT BETWEEN 0 AND 2 THEN RAISE EXCEPTION 'Invalid answer.'; END IF;
  IF v_room.question_started_at < now() - make_interval(secs => CASE v_room.game_mode WHEN 'speed_round' THEN 8 WHEN 'relaxed_round' THEN 30 ELSE 15 END) THEN
    RAISE EXCEPTION 'Time is up for this question.';
  END IF;
  IF v_room.answers ? v_user THEN RAISE EXCEPTION 'You already answered this question.'; END IF;
  v_correct := CASE p_question
    WHEN 0 THEN 0 WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 3 THEN 0 WHEN 4 THEN 1
  END;
  v_scores := v_room.scores;
  IF p_answer=v_correct THEN
    v_scores := jsonb_set(v_scores,ARRAY[v_user],to_jsonb(COALESCE((v_scores->>v_user)::integer,0)+
      CASE v_room.game_mode WHEN 'speed_round' THEN 150 WHEN 'relaxed_round' THEN 75 ELSE 100 END),true);
  ELSE
    IF NOT (v_scores ? v_user) THEN v_scores := jsonb_set(v_scores,ARRAY[v_user],'0'::jsonb,true); END IF;
  END IF;
  v_answers := jsonb_set(v_room.answers,ARRAY[v_user],jsonb_build_object('answer',p_answer,'correct',p_answer=v_correct),true);
  UPDATE public.linket_live_rooms SET scores=v_scores,answers=v_answers WHERE id=p_room_id;
  RETURN jsonb_build_object('correct',p_answer=v_correct,'score',COALESCE((v_scores->>v_user)::integer,0));
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_live_advance_question(p_room_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room public.linket_live_rooms%ROWTYPE;
  v_players integer;
  v_answered integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND OR v_room.status <> 'playing' THEN RAISE EXCEPTION 'This game is not active.'; END IF;
  IF v_room.host_user_id <> auth.uid() THEN RAISE EXCEPTION 'Only the host can advance the game.'; END IF;
  SELECT count(*) INTO v_players FROM public.linket_live_room_players WHERE room_id=p_room_id;
  SELECT count(*) INTO v_answered FROM jsonb_object_keys(v_room.answers);
  IF v_answered < v_players AND v_room.question_started_at >
    now()-make_interval(secs => CASE v_room.game_mode WHEN 'speed_round' THEN 8 WHEN 'relaxed_round' THEN 30 ELSE 15 END) THEN
    RAISE EXCEPTION 'Wait for everyone to answer or for the timer to finish.';
  END IF;
  IF v_room.current_question >= 4 THEN
    UPDATE public.linket_live_rooms SET status='finished' WHERE id=p_room_id;
    RETURN 'finished';
  END IF;
  UPDATE public.linket_live_rooms
  SET current_question=current_question+1,question_started_at=now(),answers='{}'::jsonb
  WHERE id=p_room_id;
  RETURN 'next';
END;
$$;

REVOKE ALL ON FUNCTION public.linket_live_set_mode(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.linket_live_set_mode(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.linket_live_start_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_live_submit_answer(uuid,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_live_advance_question(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.linket_live_start_game(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_live_submit_answer(uuid,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_live_advance_question(uuid) TO authenticated;
