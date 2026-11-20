-- Host-selected multiplayer match duration (5, 10, 15, or 20 minutes).
ALTER TABLE public.linket_live_rooms
  ADD COLUMN IF NOT EXISTS duration_minutes integer NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS ends_at timestamptz;

ALTER TABLE public.linket_live_rooms
  DROP CONSTRAINT IF EXISTS linket_live_rooms_duration_minutes_check;
ALTER TABLE public.linket_live_rooms
  ADD CONSTRAINT linket_live_rooms_duration_minutes_check
  CHECK (duration_minutes IN (5,10,15,20));

CREATE OR REPLACE FUNCTION public.linket_live_set_duration(p_room_id uuid,p_duration_minutes integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_room public.linket_live_rooms%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_duration_minutes NOT IN (5,10,15,20) THEN RAISE EXCEPTION 'Choose 5, 10, 15, or 20 minutes.'; END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room not found.'; END IF;
  IF v_room.host_user_id<>auth.uid() THEN RAISE EXCEPTION 'Only the host can choose the game length.'; END IF;
  IF v_room.status<>'waiting' THEN RAISE EXCEPTION 'The game has already started.'; END IF;
  UPDATE public.linket_live_rooms SET duration_minutes=p_duration_minutes WHERE id=p_room_id;
END; $$;

CREATE OR REPLACE FUNCTION public.linket_live_start_game(p_room_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_room public.linket_live_rooms%ROWTYPE; v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room not found.'; END IF;
  IF v_room.host_user_id<>auth.uid() THEN RAISE EXCEPTION 'Only the host can start the game.'; END IF;
  IF v_room.status<>'waiting' THEN RAISE EXCEPTION 'This room has already started.'; END IF;
  SELECT count(*) INTO v_count FROM public.linket_live_room_players WHERE room_id=p_room_id;
  IF v_count<2 THEN RAISE EXCEPTION 'At least 2 players are needed to start.'; END IF;
  UPDATE public.linket_live_rooms
  SET status='playing',game_mode=COALESCE(game_mode,'quiz_battle'),current_question=0,
      question_started_at=now(),ends_at=now()+make_interval(mins=>COALESCE(duration_minutes,10)),
      scores='{}'::jsonb,answers='{}'::jsonb
  WHERE id=p_room_id;
END; $$;

CREATE OR REPLACE FUNCTION public.linket_live_submit_answer(p_room_id uuid,p_question integer,p_answer integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_room public.linket_live_rooms%ROWTYPE; v_correct integer; v_user text:=auth.uid()::text; v_scores jsonb; v_answers jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND OR v_room.status<>'playing' THEN RAISE EXCEPTION 'This game is not active.'; END IF;
  IF v_room.ends_at IS NOT NULL AND now()>=v_room.ends_at THEN
    UPDATE public.linket_live_rooms SET status='finished' WHERE id=p_room_id;
    RAISE EXCEPTION 'The multiplayer match time is over.';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.linket_live_room_players WHERE room_id=p_room_id AND user_id=auth.uid()) THEN RAISE EXCEPTION 'You are not in this room.'; END IF;
  IF p_question<>v_room.current_question OR p_question<0 THEN RAISE EXCEPTION 'That question is no longer active.'; END IF;
  IF p_answer NOT BETWEEN 0 AND 2 THEN RAISE EXCEPTION 'Invalid answer.'; END IF;
  IF v_room.question_started_at<now()-make_interval(secs=>CASE v_room.game_mode WHEN 'speed_round' THEN 8 WHEN 'relaxed_round' THEN 30 ELSE 15 END) THEN RAISE EXCEPTION 'Time is up for this question.'; END IF;
  IF v_room.answers ? v_user THEN RAISE EXCEPTION 'You already answered this question.'; END IF;
  v_correct:=CASE mod(p_question,5) WHEN 0 THEN 0 WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 3 THEN 0 ELSE 1 END;
  v_scores:=COALESCE(v_room.scores,'{}'::jsonb);
  IF p_answer=v_correct THEN
    v_scores:=jsonb_set(v_scores,ARRAY[v_user],to_jsonb(COALESCE((v_scores->>v_user)::integer,0)+CASE v_room.game_mode WHEN 'speed_round' THEN 150 WHEN 'relaxed_round' THEN 75 ELSE 100 END),true);
  ELSE
    IF NOT(v_scores ? v_user) THEN v_scores:=jsonb_set(v_scores,ARRAY[v_user],'0'::jsonb,true); END IF;
  END IF;
  v_answers:=jsonb_set(COALESCE(v_room.answers,'{}'::jsonb),ARRAY[v_user],jsonb_build_object('answer',p_answer,'correct',p_answer=v_correct),true);
  UPDATE public.linket_live_rooms SET scores=v_scores,answers=v_answers WHERE id=p_room_id;
  RETURN jsonb_build_object('correct',p_answer=v_correct,'score',COALESCE((v_scores->>v_user)::integer,0));
END; $$;

CREATE OR REPLACE FUNCTION public.linket_live_advance_question(p_room_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_room public.linket_live_rooms%ROWTYPE; v_players integer; v_answered integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
  IF NOT FOUND OR v_room.status<>'playing' THEN RAISE EXCEPTION 'This game is not active.'; END IF;
  IF v_room.host_user_id<>auth.uid() AND (v_room.ends_at IS NULL OR now()<v_room.ends_at) THEN RAISE EXCEPTION 'Only the host can advance the game before the match timer ends.'; END IF;
  IF v_room.ends_at IS NOT NULL AND now()>=v_room.ends_at THEN
    UPDATE public.linket_live_rooms SET status='finished' WHERE id=p_room_id;
    RETURN 'finished';
  END IF;
  SELECT count(*) INTO v_players FROM public.linket_live_room_players WHERE room_id=p_room_id;
  SELECT count(*) INTO v_answered FROM jsonb_object_keys(COALESCE(v_room.answers,'{}'::jsonb));
  IF v_answered<v_players AND v_room.question_started_at>now()-make_interval(secs=>CASE v_room.game_mode WHEN 'speed_round' THEN 8 WHEN 'relaxed_round' THEN 30 ELSE 15 END) THEN
    RAISE EXCEPTION 'Wait for everyone to answer or for the timer to finish.';
  END IF;
  UPDATE public.linket_live_rooms SET current_question=current_question+1,question_started_at=now(),answers='{}'::jsonb WHERE id=p_room_id;
  RETURN 'next';
END; $$;

-- Custom question modules use the same match deadline.
CREATE OR REPLACE FUNCTION public.linket_module_live_start(p_room_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_room public.linket_live_rooms%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
 SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
 IF NOT FOUND OR v_room.host_user_id<>auth.uid() THEN RAISE EXCEPTION 'Only the host can start this game.'; END IF;
 IF v_room.status<>'waiting' THEN RAISE EXCEPTION 'This game has already started.'; END IF;
 IF v_room.module_id IS NULL OR jsonb_typeof(v_room.module_questions)<>'array' OR jsonb_array_length(v_room.module_questions)=0 THEN RAISE EXCEPTION 'Choose a question module first.'; END IF;
 UPDATE public.linket_live_rooms SET status='playing',current_question=0,question_started_at=now(),
   ends_at=now()+make_interval(mins=>COALESCE(v_room.duration_minutes,10)),scores='{}'::jsonb,answers='{}'::jsonb WHERE id=p_room_id;
END; $$;

CREATE OR REPLACE FUNCTION public.linket_module_live_answer(p_room_id uuid,p_question integer,p_answer integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_room public.linket_live_rooms%ROWTYPE; v_q jsonb; v_limit integer; v_points integer; v_elapsed numeric; v_user text; v_scores jsonb; v_answers jsonb; v_correct integer; v_is_correct boolean;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
 SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
 IF NOT FOUND OR v_room.status<>'playing' THEN RAISE EXCEPTION 'This game is not accepting answers.'; END IF;
 IF v_room.ends_at IS NOT NULL AND now()>=v_room.ends_at THEN UPDATE public.linket_live_rooms SET status='finished' WHERE id=p_room_id; RAISE EXCEPTION 'The multiplayer match time is over.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.linket_live_room_players WHERE room_id=p_room_id AND user_id=auth.uid()) THEN RAISE EXCEPTION 'You are not in this room.'; END IF;
 IF p_question<>v_room.current_question OR p_question<0 OR p_question>=jsonb_array_length(v_room.module_questions) THEN RAISE EXCEPTION 'That question is no longer active.'; END IF;
 v_q:=v_room.module_questions->p_question;
 IF p_answer<0 OR p_answer>=jsonb_array_length(v_q->'options') THEN RAISE EXCEPTION 'Invalid answer choice.'; END IF;
 v_limit:=CASE v_room.game_mode WHEN 'speed_round' THEN 8 WHEN 'relaxed_round' THEN 30 ELSE 15 END;
 v_points:=CASE v_room.game_mode WHEN 'speed_round' THEN 150 WHEN 'relaxed_round' THEN 75 ELSE 100 END;
 v_elapsed:=extract(epoch from(now()-v_room.question_started_at));
 IF v_elapsed>v_limit THEN RAISE EXCEPTION 'Time is up.'; END IF;
 v_user:=auth.uid()::text; v_answers:=COALESCE(v_room.answers,'{}'::jsonb);
 IF v_answers ? v_user THEN RAISE EXCEPTION 'You already answered this question.'; END IF;
 v_correct:=(v_q->>'answer')::integer; v_is_correct:=(p_answer=v_correct); v_scores:=COALESCE(v_room.scores,'{}'::jsonb);
 IF v_is_correct THEN v_scores:=jsonb_set(v_scores,ARRAY[v_user],to_jsonb(COALESCE((v_scores->>v_user)::integer,0)+v_points),true); END IF;
 v_answers:=jsonb_set(v_answers,ARRAY[v_user],jsonb_build_object('answer',p_answer,'correct',v_is_correct),true);
 UPDATE public.linket_live_rooms SET answers=v_answers,scores=v_scores WHERE id=p_room_id;
END; $$;

CREATE OR REPLACE FUNCTION public.linket_module_live_advance(p_room_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_room public.linket_live_rooms%ROWTYPE; v_count integer; v_answered integer; v_limit integer; v_total integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
 SELECT * INTO v_room FROM public.linket_live_rooms WHERE id=p_room_id FOR UPDATE;
 IF NOT FOUND OR v_room.host_user_id<>auth.uid() THEN RAISE EXCEPTION 'Only the host can advance the game.'; END IF;
 IF v_room.status<>'playing' THEN RAISE EXCEPTION 'The game is not in progress.'; END IF;
 IF v_room.ends_at IS NOT NULL AND now()>=v_room.ends_at THEN UPDATE public.linket_live_rooms SET status='finished' WHERE id=p_room_id; RETURN; END IF;
 v_limit:=CASE v_room.game_mode WHEN 'speed_round' THEN 8 WHEN 'relaxed_round' THEN 30 ELSE 15 END;
 SELECT count(*) INTO v_count FROM public.linket_live_room_players WHERE room_id=p_room_id;
 SELECT count(*) INTO v_answered FROM jsonb_object_keys(COALESCE(v_room.answers,'{}'::jsonb));
 IF extract(epoch from(now()-v_room.question_started_at))<v_limit AND v_answered<v_count THEN RAISE EXCEPTION 'Wait until everyone answers or the timer runs out.'; END IF;
 v_total:=jsonb_array_length(v_room.module_questions);
 UPDATE public.linket_live_rooms SET current_question=CASE WHEN current_question+1>=v_total THEN 0 ELSE current_question+1 END,
   question_started_at=now(),answers='{}'::jsonb WHERE id=p_room_id;
END; $$;

REVOKE ALL ON FUNCTION public.linket_live_set_duration(uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.linket_live_set_duration(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_live_start_game(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_live_submit_answer(uuid,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_live_advance_question(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_module_live_start(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_module_live_answer(uuid,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.linket_module_live_advance(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
