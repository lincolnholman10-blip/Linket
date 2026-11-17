-- Linket progression and collectible marketplace upgrade
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
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT keys.mode_key, COALESCE(progress.unlocked_level,1)
  FROM (VALUES ('tower'),('gold'),('cafe'),('factory')) AS keys(mode_key)
  LEFT JOIN public.linket_mode_progress progress
    ON progress.user_id=auth.uid() AND progress.mode_key=keys.mode_key
  WHERE auth.uid() IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.linket_answer_mode_question(p_mode_key text,p_answer integer)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE current_level integer; next_level integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first.'; END IF;
  IF p_mode_key NOT IN ('tower','gold','cafe','factory') THEN RAISE EXCEPTION 'Unknown game mode.'; END IF;
  INSERT INTO public.linket_mode_progress(user_id,mode_key,unlocked_level)
  VALUES(auth.uid(),p_mode_key,1) ON CONFLICT(user_id,mode_key) DO NOTHING;
  SELECT unlocked_level INTO current_level FROM public.linket_mode_progress
  WHERE user_id=auth.uid() AND mode_key=p_mode_key FOR UPDATE;
  IF current_level>=3 THEN RETURN current_level; END IF;
  -- Each mode's current quiz challenge has three choices; choice 0 is correct.
  IF p_answer IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'Not quite! Review the question and try again.'; END IF;
  next_level:=current_level+1;
  UPDATE public.linket_mode_progress SET unlocked_level=next_level,updated_at=now()
  WHERE user_id=auth.uid() AND mode_key=p_mode_key;
  RETURN next_level;
END; $$;

CREATE OR REPLACE FUNCTION public.linket_sell_collectibles(p_collectible_id text,p_quantity integer)
RETURNS TABLE(tokens_earned bigint,new_balance bigint,remaining_quantity integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE unit_price bigint; current_quantity integer; earned bigint;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in first.'; END IF;
  IF p_quantity IS NULL OR p_quantity<1 OR p_quantity>100000 THEN
    RAISE EXCEPTION 'Choose a quantity between 1 and 100000.';
  END IF;
  SELECT oc.quantity INTO current_quantity
  FROM public.owned_collectibles oc
  WHERE oc.user_id=auth.uid() AND oc.collectible_id=p_collectible_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'You do not own this collectible.'; END IF;
  IF p_quantity>current_quantity THEN RAISE EXCEPTION 'You do not have that many to sell.'; END IF;

  SELECT CASE
    WHEN i.rarity='Common' THEN 5
    WHEN i.rarity='Rare' THEN 15
    WHEN i.rarity='Epic' THEN 30
    WHEN i.rarity='Legendary' THEN 50
    WHEN i.rarity='Mythical' THEN 100
    ELSE 0 END INTO unit_price
  FROM (VALUES
    ('Happy Turtle','Common'),('Tiny Bee','Common'),('Bouncy Bunny','Common'),
    ('Robot Buddy','Rare'),('Frost Wolf','Epic'),('Golden Owl','Legendary'),
    ('Crystal Cat','Legendary'),('Lumi Fox','Mythical'),('Galaxy Dragon','Mythical'),
    ('Starwing','Mythical')
  ) AS i(collectible,rarity)
  WHERE i.collectible=p_collectible_id;
  IF unit_price IS NULL OR unit_price<=0 THEN RAISE EXCEPTION 'Unknown collectible.'; END IF;

  earned:=unit_price*p_quantity;
  IF p_quantity=current_quantity THEN
    DELETE FROM public.owned_collectibles WHERE user_id=auth.uid() AND collectible_id=p_collectible_id;
    remaining_quantity:=0;
  ELSE
    UPDATE public.owned_collectibles SET quantity=quantity-p_quantity
    WHERE user_id=auth.uid() AND collectible_id=p_collectible_id
    RETURNING quantity INTO remaining_quantity;
  END IF;
  UPDATE public.profiles SET tokens=tokens+earned WHERE id=auth.uid()
  RETURNING tokens INTO new_balance;
  tokens_earned:=earned;
  RETURN NEXT;
END; $$;

REVOKE ALL ON FUNCTION public.linket_get_mode_unlocks() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_answer_mode_question(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_sell_collectibles(text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.linket_get_mode_unlocks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_answer_mode_question(text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_sell_collectibles(text,integer) TO authenticated;
