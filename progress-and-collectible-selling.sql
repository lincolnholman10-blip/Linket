-- Linket progression, question unlocks, and collectible selling
-- Run this entire file once in Supabase SQL Editor.

CREATE TABLE IF NOT EXISTS public.linket_mode_progress (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  mode_key text NOT NULL CHECK (mode_key IN ('tower','gold','cafe','factory')),
  unlocked_level integer NOT NULL DEFAULT 1 CHECK (unlocked_level BETWEEN 1 AND 3),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, mode_key)
);

ALTER TABLE public.linket_mode_progress ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.linket_mode_progress FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.linket_get_mode_unlocks()
RETURNS TABLE(mode_key text, unlocked_level integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_user uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Please sign in to load your game progress.';
  END IF;

  INSERT INTO public.linket_mode_progress(user_id, mode_key)
  VALUES
    (v_user, 'tower'),
    (v_user, 'gold'),
    (v_user, 'cafe'),
    (v_user, 'factory')
  ON CONFLICT (user_id, mode_key) DO NOTHING;

  RETURN QUERY
  SELECT p.mode_key, p.unlocked_level
  FROM public.linket_mode_progress p
  WHERE p.user_id = v_user
  ORDER BY CASE p.mode_key
    WHEN 'tower' THEN 1 WHEN 'gold' THEN 2 WHEN 'cafe' THEN 3 ELSE 4 END;
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_answer_mode_question(
  p_mode_key text,
  p_answer integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_level integer;
  v_correct_answer integer := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Please sign in before answering a question.';
  END IF;
  IF p_mode_key NOT IN ('tower','gold','cafe','factory') THEN
    RAISE EXCEPTION 'Unknown game mode.';
  END IF;
  IF p_answer NOT BETWEEN 0 AND 2 THEN
    RAISE EXCEPTION 'Choose one of the three answers.';
  END IF;

  INSERT INTO public.linket_mode_progress(user_id, mode_key)
  VALUES (v_user, p_mode_key)
  ON CONFLICT (user_id, mode_key) DO NOTHING;

  SELECT p.unlocked_level
  INTO v_level
  FROM public.linket_mode_progress p
  WHERE p.user_id = v_user AND p.mode_key = p_mode_key
  FOR UPDATE;

  IF v_level >= 3 THEN
    RETURN v_level;
  END IF;

  -- The two stage-unlock questions for each mode are checked here,
  -- on the server, rather than trusting the answer shown in the browser.
  CASE p_mode_key
    WHEN 'tower' THEN v_correct_answer := CASE v_level WHEN 1 THEN 0 WHEN 2 THEN 0 END;
    WHEN 'gold' THEN v_correct_answer := CASE v_level WHEN 1 THEN 0 WHEN 2 THEN 0 END;
    WHEN 'cafe' THEN v_correct_answer := CASE v_level WHEN 1 THEN 0 WHEN 2 THEN 0 END;
    WHEN 'factory' THEN v_correct_answer := CASE v_level WHEN 1 THEN 0 WHEN 2 THEN 0 END;
  END CASE;

  IF p_answer <> v_correct_answer THEN
    RAISE EXCEPTION 'That answer is not correct yet. Try again!';
  END IF;

  UPDATE public.linket_mode_progress
  SET unlocked_level = LEAST(v_level + 1, 3),
      updated_at = now()
  WHERE user_id = v_user AND mode_key = p_mode_key
  RETURNING unlocked_level INTO v_level;

  RETURN v_level;
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_sell_collectibles(
  p_collectible_id text,
  p_quantity integer
)
RETURNS TABLE(tokens_earned bigint, new_balance bigint, remaining_quantity integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.linket_get_mode_unlocks() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_answer_mode_question(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_sell_collectibles(text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.linket_get_mode_unlocks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_answer_mode_question(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_sell_collectibles(text, integer) TO authenticated;
