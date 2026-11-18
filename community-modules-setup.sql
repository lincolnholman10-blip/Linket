-- Linket Community Question Modules + shared multiplayer module engine
create table if not exists public.linket_question_modules (
 id uuid primary key default gen_random_uuid(),
 creator_id uuid not null references auth.users(id) on delete cascade,
 creator_name text,
 title text not null check (char_length(title) between 3 and 60),
 description text not null default '',
 questions jsonb not null,
 is_public boolean not null default true,
 created_at timestamptz not null default now(),
 constraint linket_module_questions_array check (
  jsonb_typeof(questions) = 'array'
  and jsonb_array_length(questions) between 1 and 30
 )
);
alter table public.linket_question_modules enable row level security;
drop policy if exists "Linket modules readable by owner or public" on public.linket_question_modules;
create policy "Linket modules readable by owner or public" on public.linket_question_modules
 for select to authenticated using (is_public = true or creator_id = auth.uid());
drop policy if exists "Players create their own Linket modules" on public.linket_question_modules;
create policy "Players create their own Linket modules" on public.linket_question_modules
 for insert to authenticated with check (creator_id = auth.uid());
drop policy if exists "Players update their own Linket modules" on public.linket_question_modules;
create policy "Players update their own Linket modules" on public.linket_question_modules
 for update to authenticated using (creator_id = auth.uid()) with check (creator_id = auth.uid());
drop policy if exists "Players delete their own Linket modules" on public.linket_question_modules;
create policy "Players delete their own Linket modules" on public.linket_question_modules
 for delete to authenticated using (creator_id = auth.uid());
grant select, insert, update, delete on public.linket_question_modules to authenticated;

alter table public.linket_live_rooms
 add column if not exists module_id uuid references public.linket_question_modules(id) on delete set null,
 add column if not exists module_questions jsonb;

create or replace function public.linket_module_live_select(p_room_id uuid, p_module_id uuid)
returns void language plpgsql security definer set search_path = public, auth
as $$
declare v_room public.linket_live_rooms%rowtype; v_module public.linket_question_modules%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 select * into v_room from public.linket_live_rooms where id=p_room_id for update;
 if not found or v_room.host_user_id <> auth.uid() then raise exception 'Only the host can choose a module.'; end if;
 if v_room.status <> 'waiting' then raise exception 'The game has already started.'; end if;
 if p_module_id is null then
  update public.linket_live_rooms set module_id=null,module_questions=null where id=p_room_id;
 else
  select * into v_module from public.linket_question_modules where id=p_module_id and (is_public or creator_id=auth.uid());
  if not found then raise exception 'That module is not available.'; end if;
  update public.linket_live_rooms set module_id=v_module.id,module_questions=v_module.questions where id=p_room_id;
 end if;
end; $$;

create or replace function public.linket_module_live_start(p_room_id uuid)
returns void language plpgsql security definer set search_path = public, auth
as $$
declare v_room public.linket_live_rooms%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 select * into v_room from public.linket_live_rooms where id=p_room_id for update;
 if not found or v_room.host_user_id <> auth.uid() then raise exception 'Only the host can start this game.'; end if;
 if v_room.status <> 'waiting' then raise exception 'This game has already started.'; end if;
 if v_room.module_id is null or jsonb_typeof(v_room.module_questions) <> 'array' or jsonb_array_length(v_room.module_questions)=0 then raise exception 'Choose a question module first.'; end if;
 update public.linket_live_rooms set status='playing',current_question=0,question_started_at=now(),scores='{}'::jsonb,answers='{}'::jsonb where id=p_room_id;
end; $$;

create or replace function public.linket_module_live_answer(p_room_id uuid,p_question integer,p_answer integer)
returns void language plpgsql security definer set search_path = public, auth
as $$
declare
 v_room public.linket_live_rooms%rowtype; v_q jsonb; v_correct integer; v_limit integer; v_points integer;
 v_elapsed numeric; v_user text; v_scores jsonb; v_answers jsonb; v_is_correct boolean;
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 select * into v_room from public.linket_live_rooms where id=p_room_id for update;
 if not found or v_room.status <> 'playing' then raise exception 'This game is not accepting answers.'; end if;
 if not exists(select 1 from public.linket_live_room_players where room_id=p_room_id and user_id=auth.uid()) then raise exception 'You are not in this room.'; end if;
 if p_question <> v_room.current_question then raise exception 'That question is no longer active.'; end if;
 if p_question < 0 or p_question >= jsonb_array_length(v_room.module_questions) then raise exception 'Invalid question.'; end if;
 v_q:=v_room.module_questions->p_question;
 if p_answer < 0 or p_answer >= jsonb_array_length(v_q->'options') then raise exception 'Invalid answer choice.'; end if;
 v_limit:=case v_room.game_mode when 'speed_round' then 8 when 'relaxed_round' then 30 else 15 end;
 v_points:=case v_room.game_mode when 'speed_round' then 150 when 'relaxed_round' then 75 else 100 end;
 v_elapsed:=extract(epoch from (now()-v_room.question_started_at));
 if v_elapsed > v_limit then raise exception 'Time is up.'; end if;
 v_user:=auth.uid()::text; v_answers:=coalesce(v_room.answers,'{}'::jsonb);
 if v_answers ? v_user then raise exception 'You already answered this question.'; end if;
 v_correct:=(v_q->>'answer')::integer; v_is_correct:=(p_answer=v_correct);
 v_scores:=coalesce(v_room.scores,'{}'::jsonb);
 if v_is_correct then v_scores:=jsonb_set(v_scores,array[v_user],to_jsonb(coalesce((v_scores->>v_user)::integer,0)+v_points),true); end if;
 v_answers:=jsonb_set(v_answers,array[v_user],jsonb_build_object('answer',p_answer,'correct',v_is_correct),true);
 update public.linket_live_rooms set answers=v_answers,scores=v_scores where id=p_room_id;
end; $$;

create or replace function public.linket_module_live_advance(p_room_id uuid)
returns void language plpgsql security definer set search_path = public, auth
as $$
declare v_room public.linket_live_rooms%rowtype; v_count integer; v_answered integer; v_limit integer; v_total integer;
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 select * into v_room from public.linket_live_rooms where id=p_room_id for update;
 if not found or v_room.host_user_id <> auth.uid() then raise exception 'Only the host can advance the game.'; end if;
 if v_room.status <> 'playing' then raise exception 'The game is not in progress.'; end if;
 v_limit:=case v_room.game_mode when 'speed_round' then 8 when 'relaxed_round' then 30 else 15 end;
 select count(*) into v_count from public.linket_live_room_players where room_id=p_room_id;
 select count(*) into v_answered from jsonb_object_keys(coalesce(v_room.answers,'{}'::jsonb));
 if extract(epoch from (now()-v_room.question_started_at)) < v_limit and v_answered < v_count then
  raise exception 'Wait until everyone answers or the timer runs out.';
 end if;
 v_total:=jsonb_array_length(v_room.module_questions);
 if v_room.current_question+1 >= v_total then
  update public.linket_live_rooms set status='finished' where id=p_room_id;
 else
  update public.linket_live_rooms set current_question=current_question+1,question_started_at=now(),answers='{}'::jsonb where id=p_room_id;
 end if;
end; $$;

revoke all on function public.linket_module_live_select(uuid,uuid) from public;
revoke all on function public.linket_module_live_start(uuid) from public;
revoke all on function public.linket_module_live_answer(uuid,integer,integer) from public;
revoke all on function public.linket_module_live_advance(uuid) from public;
grant execute on function public.linket_module_live_select(uuid,uuid) to authenticated;
grant execute on function public.linket_module_live_start(uuid) to authenticated;
grant execute on function public.linket_module_live_answer(uuid,integer,integer) to authenticated;
grant execute on function public.linket_module_live_advance(uuid) to authenticated;
