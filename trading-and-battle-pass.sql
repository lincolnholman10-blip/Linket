-- Linket Trading and Battle Pass
-- Run this entire file in Supabase SQL Editor after the matching index.html is deployed.

-- Secure player-to-player trades. Offered collectibles are held in escrow until
-- the recipient accepts, or returned when a trade is declined/cancelled.
CREATE TABLE IF NOT EXISTS public.linket_trades (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  offered_items jsonb NOT NULL,
  requested_items jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (sender_user_id <> recipient_user_id),
  CHECK (jsonb_typeof(offered_items) = 'array' AND jsonb_array_length(offered_items) > 0),
  CHECK (jsonb_typeof(requested_items) = 'array' AND jsonb_array_length(requested_items) > 0)
);
ALTER TABLE public.linket_trades ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.linket_trades FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.linket_trade_players()
RETURNS TABLE(player_id uuid, username text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT p.id, p.username
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL AND p.id <> auth.uid()
    AND COALESCE(p.is_banned,false)=false
  ORDER BY lower(p.username)
  LIMIT 200;
$$;

CREATE OR REPLACE FUNCTION public.linket_trade_list()
RETURNS TABLE(
  trade_id uuid, sender_id uuid, sender_username text,
  recipient_id uuid, recipient_username text,
  offered_items jsonb, requested_items jsonb, trade_status text, created_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT t.id,t.sender_user_id,sp.username,t.recipient_user_id,rp.username,
         t.offered_items,t.requested_items,t.status,t.created_at
  FROM public.linket_trades t
  JOIN public.profiles sp ON sp.id=t.sender_user_id
  JOIN public.profiles rp ON rp.id=t.recipient_user_id
  WHERE auth.uid() IN (t.sender_user_id,t.recipient_user_id)
  ORDER BY t.created_at DESC
  LIMIT 100;
$$;

CREATE OR REPLACE FUNCTION public.linket_trade_create(
  p_recipient uuid, p_offered jsonb, p_requested jsonb
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_user uuid := auth.uid();
  v_item record;
  v_qty integer;
  v_owned integer;
  v_trade uuid;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Please sign in before trading.'; END IF;
  IF p_recipient IS NULL OR p_recipient=v_user THEN RAISE EXCEPTION 'Choose another player.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_recipient AND COALESCE(is_banned,false)=false) THEN
    RAISE EXCEPTION 'That player is unavailable.';
  END IF;
  IF jsonb_typeof(p_offered)<>'array' OR jsonb_array_length(p_offered)<1 OR jsonb_array_length(p_offered)>5
     OR jsonb_typeof(p_requested)<>'array' OR jsonb_array_length(p_requested)<1 OR jsonb_array_length(p_requested)>5 THEN
    RAISE EXCEPTION 'Choose 1–5 offered collectibles and 1–5 requested collectibles.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_offered) x
    WHERE jsonb_typeof(x)<>'object' OR NOT (x ? 'collectible_id') OR NOT (x ? 'quantity')
       OR COALESCE(x->>'collectible_id','')='' OR COALESCE((x->>'quantity')::integer,0)<1
       OR (x->>'quantity')::integer>100
  ) OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_requested) x
    WHERE jsonb_typeof(x)<>'object' OR NOT (x ? 'collectible_id') OR NOT (x ? 'quantity')
       OR COALESCE(x->>'collectible_id','')='' OR COALESCE((x->>'quantity')::integer,0)<1
       OR (x->>'quantity')::integer>100
  ) THEN RAISE EXCEPTION 'Invalid collectible or quantity in the trade.'; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(p_offered)) <>
     (SELECT count(DISTINCT x->>'collectible_id') FROM jsonb_array_elements(p_offered) x)
     OR (SELECT count(*) FROM jsonb_array_elements(p_requested)) <>
     (SELECT count(DISTINCT x->>'collectible_id') FROM jsonb_array_elements(p_requested) x) THEN
    RAISE EXCEPTION 'Each collectible can only appear once per side of a trade.';
  END IF;
  FOR v_item IN SELECT x->>'collectible_id' AS collectible_id,(x->>'quantity')::integer AS quantity
                FROM jsonb_array_elements(p_offered) x LOOP
    IF NOT EXISTS(SELECT 1 FROM public.owned_collectibles WHERE user_id=v_user AND collectible_id=v_item.collectible_id AND quantity>=v_item.quantity) THEN
      RAISE EXCEPTION 'You do not own enough copies of %.',v_item.collectible_id;
    END IF;
  END LOOP;
  FOR v_item IN SELECT x->>'collectible_id' AS collectible_id,(x->>'quantity')::integer AS quantity
                FROM jsonb_array_elements(p_offered) x LOOP
    UPDATE public.owned_collectibles SET quantity=quantity-v_item.quantity
    WHERE user_id=v_user AND collectible_id=v_item.collectible_id;
    DELETE FROM public.owned_collectibles WHERE user_id=v_user AND collectible_id=v_item.collectible_id AND quantity<=0;
  END LOOP;
  INSERT INTO public.linket_trades(sender_user_id,recipient_user_id,offered_items,requested_items)
  VALUES(v_user,p_recipient,p_offered,p_requested) RETURNING id INTO v_trade;
  RETURN v_trade;
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_trade_respond(p_trade_id uuid,p_action text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_trade public.linket_trades%ROWTYPE;
  v_item record;
  v_owned integer;
  v_from uuid;
  v_to uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in before managing trades.'; END IF;
  IF p_action NOT IN ('accept','reject','cancel') THEN RAISE EXCEPTION 'Invalid trade action.'; END IF;
  SELECT * INTO v_trade FROM public.linket_trades WHERE id=p_trade_id FOR UPDATE;
  IF NOT FOUND OR v_trade.status<>'pending' THEN RAISE EXCEPTION 'This trade is no longer pending.'; END IF;

  IF p_action='accept' THEN
    IF auth.uid()<>v_trade.recipient_user_id THEN RAISE EXCEPTION 'Only the recipient can accept this trade.'; END IF;
    v_from:=v_trade.recipient_user_id; v_to:=v_trade.sender_user_id;
    FOR v_item IN SELECT x->>'collectible_id' AS collectible_id,(x->>'quantity')::integer AS quantity
                  FROM jsonb_array_elements(v_trade.requested_items) x LOOP
      SELECT quantity INTO v_owned FROM public.owned_collectibles
      WHERE user_id=v_from AND collectible_id=v_item.collectible_id FOR UPDATE;
      IF NOT FOUND OR v_owned<v_item.quantity THEN
        RAISE EXCEPTION 'You no longer own enough copies of % to accept this trade.',v_item.collectible_id;
      END IF;
    END LOOP;
    FOR v_item IN SELECT x->>'collectible_id' AS collectible_id,(x->>'quantity')::integer AS quantity
                  FROM jsonb_array_elements(v_trade.requested_items) x LOOP
      UPDATE public.owned_collectibles SET quantity=quantity-v_item.quantity
      WHERE user_id=v_from AND collectible_id=v_item.collectible_id;
      DELETE FROM public.owned_collectibles WHERE user_id=v_from AND collectible_id=v_item.collectible_id AND quantity<=0;
      INSERT INTO public.owned_collectibles(user_id,collectible_id,quantity)
      VALUES(v_to,v_item.collectible_id,v_item.quantity)
      ON CONFLICT(user_id,collectible_id) DO UPDATE
      SET quantity=public.owned_collectibles.quantity+EXCLUDED.quantity;
    END LOOP;
    FOR v_item IN SELECT x->>'collectible_id' AS collectible_id,(x->>'quantity')::integer AS quantity
                  FROM jsonb_array_elements(v_trade.offered_items) x LOOP
      INSERT INTO public.owned_collectibles(user_id,collectible_id,quantity)
      VALUES(v_from,v_item.collectible_id,v_item.quantity)
      ON CONFLICT(user_id,collectible_id) DO UPDATE
      SET quantity=public.owned_collectibles.quantity+EXCLUDED.quantity;
    END LOOP;
    UPDATE public.linket_trades SET status='accepted',updated_at=now() WHERE id=p_trade_id;
    RETURN 'Trade completed!';
  END IF;

  IF p_action='reject' AND auth.uid()<>v_trade.recipient_user_id THEN
    RAISE EXCEPTION 'Only the recipient can reject this trade.';
  ELSIF p_action='cancel' AND auth.uid()<>v_trade.sender_user_id THEN
    RAISE EXCEPTION 'Only the sender can cancel this trade.';
  END IF;

  FOR v_item IN SELECT x->>'collectible_id' AS collectible_id,(x->>'quantity')::integer AS quantity
                FROM jsonb_array_elements(v_trade.offered_items) x LOOP
    INSERT INTO public.owned_collectibles(user_id,collectible_id,quantity)
    VALUES(v_trade.sender_user_id,v_item.collectible_id,v_item.quantity)
    ON CONFLICT(user_id,collectible_id) DO UPDATE
    SET quantity=public.owned_collectibles.quantity+EXCLUDED.quantity;
  END LOOP;
  UPDATE public.linket_trades SET status=CASE p_action WHEN 'reject' THEN 'rejected' ELSE 'cancelled' END,updated_at=now()
  WHERE id=p_trade_id;
  RETURN CASE p_action WHEN 'reject' THEN 'Trade declined. Offered collectibles returned.' ELSE 'Trade cancelled. Offered collectibles returned.' END;
END;
$$;

-- Battle Pass progression. XP is awarded only inside trusted answer RPCs below.
CREATE TABLE IF NOT EXISTS public.linket_battlepass_progress (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  xp integer NOT NULL DEFAULT 0 CHECK (xp>=0),
  premium_unlocked boolean NOT NULL DEFAULT false,
  claimed_tiers integer[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.linket_battlepass_progress ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.linket_battlepass_progress FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.linket_battlepass_get()
RETURNS TABLE(xp integer,premium_unlocked boolean,claimed_tiers integer[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in.'; END IF;
 INSERT INTO public.linket_battlepass_progress(user_id) VALUES(auth.uid()) ON CONFLICT DO NOTHING;
 RETURN QUERY SELECT b.xp,b.premium_unlocked,b.claimed_tiers
 FROM public.linket_battlepass_progress b WHERE b.user_id=auth.uid();
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_battlepass_unlock_premium()
RETURNS TABLE(xp integer,premium_unlocked boolean,claimed_tiers integer[],tokens bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_tokens bigint;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in.'; END IF;
 INSERT INTO public.linket_battlepass_progress(user_id) VALUES(auth.uid()) ON CONFLICT DO NOTHING;
 SELECT p.tokens INTO v_tokens FROM public.profiles p WHERE p.id=auth.uid() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Player profile not found.'; END IF;
 IF EXISTS(SELECT 1 FROM public.linket_battlepass_progress WHERE user_id=auth.uid() AND premium_unlocked) THEN
   RAISE EXCEPTION 'Premium rewards are already unlocked.';
 END IF;
 IF v_tokens<500 THEN RAISE EXCEPTION 'You need 500 tokens to unlock the premium track.'; END IF;
 UPDATE public.profiles SET tokens=tokens-500 WHERE id=auth.uid() RETURNING profiles.tokens INTO v_tokens;
 UPDATE public.linket_battlepass_progress SET premium_unlocked=true,updated_at=now() WHERE user_id=auth.uid();
 RETURN QUERY SELECT b.xp,b.premium_unlocked,b.claimed_tiers,v_tokens
 FROM public.linket_battlepass_progress b WHERE b.user_id=auth.uid();
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_battlepass_claim(p_tier integer)
RETURNS TABLE(xp integer,premium_unlocked boolean,claimed_tiers integer[],tokens bigint,reward_text text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 v_xp integer; v_premium boolean; v_claimed integer[]; v_tokens bigint;
 v_reward_tokens integer; v_collectible text; v_tier integer:=p_tier;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Please sign in.'; END IF;
 IF v_tier NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Invalid reward tier.'; END IF;
 INSERT INTO public.linket_battlepass_progress(user_id) VALUES(auth.uid()) ON CONFLICT DO NOTHING;
 SELECT b.xp,b.premium_unlocked,b.claimed_tiers INTO v_xp,v_premium,v_claimed
 FROM public.linket_battlepass_progress b WHERE b.user_id=auth.uid() FOR UPDATE;
 IF v_xp<v_tier*100 THEN RAISE EXCEPTION 'Earn more XP to unlock this tier.'; END IF;
 IF v_tier=ANY(v_claimed) THEN RAISE EXCEPTION 'You already claimed this tier.'; END IF;

 v_reward_tokens:=CASE WHEN v_tier IN (1,3,5,7,9,11,13,15,17,19) THEN 25+v_tier*5 ELSE 0 END;
 IF v_reward_tokens>0 THEN
   UPDATE public.profiles SET tokens=tokens+v_reward_tokens WHERE id=auth.uid() RETURNING profiles.tokens INTO v_tokens;
 ELSE
   SELECT tokens INTO v_tokens FROM public.profiles WHERE id=auth.uid();
 END IF;
 IF v_premium AND v_tier IN (2,6,10,14,18) THEN
   v_collectible:=CASE v_tier WHEN 2 THEN 'Frost Wolf' WHEN 6 THEN 'Golden Owl' WHEN 10 THEN 'Crystal Cat' WHEN 14 THEN 'Lumi Fox' ELSE 'Galaxy Dragon' END;
   INSERT INTO public.owned_collectibles(user_id,collectible_id,quantity)
   VALUES(auth.uid(),v_collectible,1)
   ON CONFLICT(user_id,collectible_id) DO UPDATE SET quantity=public.owned_collectibles.quantity+1;
 END IF;
 UPDATE public.linket_battlepass_progress SET claimed_tiers=array_append(claimed_tiers,v_tier),updated_at=now()
 WHERE user_id=auth.uid() RETURNING linket_battlepass_progress.xp,linket_battlepass_progress.premium_unlocked,linket_battlepass_progress.claimed_tiers
 INTO xp,premium_unlocked,claimed_tiers;
 tokens:=v_tokens;
 reward_text:=CASE WHEN v_reward_tokens>0 THEN v_reward_tokens||' tokens'
   WHEN v_premium AND v_tier IN (2,6,10,14,18) THEN v_collectible
   ELSE 'XP milestone claimed' END;
 RETURN NEXT;
END;
$$;

-- Award XP only from the server-validated correct-answer RPCs.
CREATE OR REPLACE FUNCTION public.linket_answer_question(p_question integer,p_answer integer)
RETURNS TABLE(correct boolean,tokens bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_correct_answer integer; v_tokens bigint; v_user_id uuid:=auth.uid();
BEGIN
 IF v_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
 v_correct_answer:=CASE p_question WHEN 0 THEN 2 WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 3 THEN 2 ELSE NULL END;
 IF v_correct_answer IS NULL THEN RAISE EXCEPTION 'Invalid question.'; END IF;
 IF p_answer=v_correct_answer THEN
   UPDATE public.profiles p SET tokens=p.tokens+25 WHERE p.id=v_user_id RETURNING p.tokens INTO v_tokens;
   IF NOT FOUND THEN RAISE EXCEPTION 'Player profile not found.'; END IF;
   INSERT INTO public.linket_battlepass_progress(user_id,xp) VALUES(v_user_id,10)
   ON CONFLICT(user_id) DO UPDATE SET xp=public.linket_battlepass_progress.xp+10,updated_at=now();
   RETURN QUERY SELECT true,v_tokens;
 ELSE
   SELECT p.tokens INTO v_tokens FROM public.profiles p WHERE p.id=v_user_id;
   IF NOT FOUND THEN RAISE EXCEPTION 'Player profile not found.'; END IF;
   RETURN QUERY SELECT false,v_tokens;
 END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.linket_answer_mode_question(p_mode_key text,p_answer integer)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_user uuid:=auth.uid(); v_level integer; v_correct_answer integer:=0;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'Please sign in before answering a question.'; END IF;
 IF p_mode_key NOT IN ('tower','gold','cafe','factory') THEN RAISE EXCEPTION 'Unknown game mode.'; END IF;
 IF p_answer NOT BETWEEN 0 AND 2 THEN RAISE EXCEPTION 'Choose one of the three answers.'; END IF;
 INSERT INTO public.linket_mode_progress(user_id,mode_key)
 VALUES(v_user,p_mode_key) ON CONFLICT(user_id,mode_key) DO NOTHING;
 SELECT p.unlocked_level INTO v_level FROM public.linket_mode_progress p
 WHERE p.user_id=v_user AND p.mode_key=p_mode_key FOR UPDATE;
 IF v_level>=3 THEN RETURN v_level; END IF;
 IF p_answer<>v_correct_answer THEN RAISE EXCEPTION 'That answer is not correct yet. Try again!'; END IF;
 UPDATE public.linket_mode_progress SET unlocked_level=LEAST(v_level+1,3),updated_at=now()
 WHERE user_id=v_user AND mode_key=p_mode_key RETURNING unlocked_level INTO v_level;
 INSERT INTO public.linket_battlepass_progress(user_id,xp) VALUES(v_user,50)
 ON CONFLICT(user_id) DO UPDATE SET xp=public.linket_battlepass_progress.xp+50,updated_at=now();
 RETURN v_level;
END;
$$;

REVOKE ALL ON FUNCTION public.linket_trade_players() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_trade_list() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_trade_create(uuid,jsonb,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_trade_respond(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_battlepass_get() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_battlepass_unlock_premium() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_battlepass_claim(integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_answer_question(integer,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.linket_answer_mode_question(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.linket_trade_players() TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_trade_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_trade_create(uuid,jsonb,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_trade_respond(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_battlepass_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_battlepass_unlock_premium() TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_battlepass_claim(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_answer_question(integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_answer_mode_question(text,integer) TO authenticated;
