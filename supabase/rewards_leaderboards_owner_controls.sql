-- Linket rewards, leaderboards, quests, and achievement controls
create table if not exists public.linket_daily_claims (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_claim_date date not null,
  streak integer not null default 0 check (streak >= 0),
  total_claims bigint not null default 0 check (total_claims >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.linket_daily_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default true,
  base_reward integer not null default 50 check (base_reward between 0 and 1000000),
  streak_bonus integer not null default 10 check (streak_bonus between 0 and 100000),
  max_streak_bonus integer not null default 7 check (max_streak_bonus between 1 and 365),
  updated_at timestamptz not null default now()
);
insert into public.linket_daily_settings(id) values (true) on conflict (id) do nothing;

create table if not exists public.linket_game_results (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_key text not null,
  score integer not null default 0 check (score >= 0),
  won boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists linket_game_results_user_idx on public.linket_game_results(user_id, created_at desc);

create table if not exists public.linket_quests (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  target_type text not null default 'wins' check (target_type in ('wins','score','tokens','collectibles')),
  target_value integer not null default 1 check (target_value > 0),
  reward_tokens integer not null default 25 check (reward_tokens >= 0),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.linket_achievements (
  id text primary key,
  title text not null,
  description text not null default '',
  icon text not null default '🏆',
  metric text not null default 'wins' check (metric in ('wins','score','tokens','collectibles')),
  target_value integer not null default 1 check (target_value > 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.linket_daily_claims enable row level security;
alter table public.linket_daily_settings enable row level security;
alter table public.linket_game_results enable row level security;
alter table public.linket_quests enable row level security;
alter table public.linket_achievements enable row level security;
revoke all on public.linket_daily_claims, public.linket_daily_settings, public.linket_game_results, public.linket_quests, public.linket_achievements from anon, authenticated;

create or replace function public.linket_claim_daily_reward()
returns table(claimed boolean, reward_tokens integer, current_streak integer, total_claims bigint, next_claim_at timestamptz, message text)
language plpgsql security definer set search_path=public,auth
as $$
declare
  v_user uuid := auth.uid();
  v_today date := (now() at time zone 'UTC')::date;
  v_last date;
  v_streak integer;
  v_total bigint;
  v_base integer;
  v_bonus integer;
  v_cap integer;
  v_enabled boolean;
  v_reward integer;
begin
  if v_user is null then raise exception 'Please sign in to claim your daily reward.'; end if;
  select enabled,base_reward,streak_bonus,max_streak_bonus into v_enabled,v_base,v_bonus,v_cap
    from public.linket_daily_settings where id=true;
  if not coalesce(v_enabled,true) then
    return query select false,0,0,0::bigint,(date_trunc('day',now() at time zone 'UTC') + interval '1 day') at time zone 'UTC','Daily rewards are temporarily disabled.';
    return;
  end if;
  insert into public.linket_daily_claims(user_id,last_claim_date,streak,total_claims)
    values(v_user,v_today-1,0,0) on conflict(user_id) do nothing;
  select last_claim_date,streak,total_claims into v_last,v_streak,v_total
    from public.linket_daily_claims where user_id=v_user for update;
  if v_last=v_today then
    return query select false,0,v_streak,v_total,(date_trunc('day',now() at time zone 'UTC') + interval '1 day') at time zone 'UTC','You already claimed today. Come back tomorrow!';
    return;
  end if;
  if v_last=v_today-1 then v_streak:=v_streak+1; else v_streak:=1; end if;
  v_total:=v_total+1;
  v_reward:=greatest(0,v_base + least(v_streak-1,v_cap)*v_bonus);
  update public.linket_daily_claims set last_claim_date=v_today,streak=v_streak,total_claims=v_total,updated_at=now() where user_id=v_user;
  update public.profiles set tokens=coalesce(tokens,0)+v_reward where id=v_user;
  return query select true,v_reward,v_streak,v_total,(date_trunc('day',now() at time zone 'UTC') + interval '1 day') at time zone 'UTC','Daily reward claimed!';
end $$;

create or replace function public.linket_record_game_result(p_mode_key text,p_score integer,p_won boolean default true)
returns void language plpgsql security definer set search_path=public,auth
as $$
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  if p_mode_key is null or length(trim(p_mode_key))=0 or length(p_mode_key)>40 then raise exception 'Invalid game mode.'; end if;
  if p_score is null or p_score<0 then raise exception 'Invalid score.'; end if;
  insert into public.linket_game_results(user_id,mode_key,score,won)
  values(auth.uid(),lower(trim(p_mode_key)),p_score,coalesce(p_won,true));
end $$;

create or replace function public.linket_get_leaderboard(p_category text default 'tokens',p_limit integer default 50)
returns table(rank bigint,user_id uuid,username text,score numeric,detail text)
language plpgsql security definer set search_path=public,auth
as $$
begin
  if p_category not in ('tokens','collectibles','wins','score') then raise exception 'Unknown leaderboard category.'; end if;
  return query
  with stats as (
    select p.id,p.username,coalesce(p.tokens,0)::numeric as token_score,
      coalesce(c.collectible_total,0)::numeric as collectible_score,
      coalesce(g.win_total,0)::numeric as wins_score,
      coalesce(g.best_score,0)::numeric as best_score
    from public.profiles p
    left join (select user_id,sum(quantity)::bigint collectible_total from public.owned_collectibles group by user_id) c on c.user_id=p.id
    left join (select user_id,count(*) filter(where won)::bigint win_total,max(score)::bigint best_score from public.linket_game_results group by user_id) g on g.user_id=p.id
    where coalesce(p.is_banned,false)=false
  ), ranked as (
    select s.*,case p_category when 'tokens' then token_score when 'collectibles' then collectible_score when 'wins' then wins_score else best_score end as metric
    from stats s
  )
  select row_number() over(order by metric desc,username asc),id,username,metric,
    case p_category when 'tokens' then 'tokens' when 'collectibles' then 'collectibles owned' when 'wins' then 'game wins' else 'best game score' end
  from ranked order by metric desc,username asc limit greatest(1,least(coalesce(p_limit,50),100));
end $$;

create or replace function public.linket_get_quest_board()
returns table(id uuid,title text,description text,target_type text,target_value integer,reward_tokens integer,enabled boolean)
language sql security definer set search_path=public
as $$ select q.id,q.title,q.description,q.target_type,q.target_value,q.reward_tokens,q.enabled
from public.linket_quests q where q.enabled=true order by q.created_at desc limit 30 $$;

create or replace function public.linket_get_achievement_board()
returns table(id text,title text,description text,icon text,metric text,target_value integer,enabled boolean)
language sql security definer set search_path=public
as $$ select a.id,a.title,a.description,a.icon,a.metric,a.target_value,a.enabled
from public.linket_achievements a where a.enabled=true order by a.target_value,a.title $$;

create or replace function public.linket_owner_save_daily_settings(p_enabled boolean,p_base_reward integer,p_streak_bonus integer,p_max_streak_bonus integer)
returns void language plpgsql security definer set search_path=public
as $$
begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 if p_base_reward<0 or p_base_reward>1000000 or p_streak_bonus<0 or p_streak_bonus>100000 or p_max_streak_bonus<1 or p_max_streak_bonus>365 then raise exception 'Reward settings are outside the allowed range.'; end if;
 insert into public.linket_daily_settings(id,enabled,base_reward,streak_bonus,max_streak_bonus,updated_at)
 values(true,p_enabled,p_base_reward,p_streak_bonus,p_max_streak_bonus,now())
 on conflict(id) do update set enabled=excluded.enabled,base_reward=excluded.base_reward,streak_bonus=excluded.streak_bonus,max_streak_bonus=excluded.max_streak_bonus,updated_at=now();
end $$;

create or replace function public.linket_owner_get_daily_settings()
returns table(enabled boolean,base_reward integer,streak_bonus integer,max_streak_bonus integer)
language plpgsql security definer set search_path=public
as $$
begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 return query select s.enabled,s.base_reward,s.streak_bonus,s.max_streak_bonus from public.linket_daily_settings s where s.id=true;
end $$;

create or replace function public.linket_owner_save_quest(p_id uuid,p_title text,p_description text,p_target_type text,p_target_value integer,p_reward_tokens integer,p_enabled boolean)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 if length(trim(coalesce(p_title,'')))=0 or length(p_title)>100 or p_target_type not in ('wins','score','tokens','collectibles') or p_target_value<1 or p_reward_tokens<0 or p_reward_tokens>1000000 then raise exception 'Invalid quest settings.'; end if;
 if p_id is null then
  insert into public.linket_quests(title,description,target_type,target_value,reward_tokens,enabled)
  values(trim(p_title),coalesce(p_description,''),p_target_type,p_target_value,p_reward_tokens,p_enabled) returning id into v_id;
 else
  update public.linket_quests set title=trim(p_title),description=coalesce(p_description,''),target_type=p_target_type,target_value=p_target_value,reward_tokens=p_reward_tokens,enabled=p_enabled,updated_at=now() where id=p_id returning id into v_id;
 end if;
 if v_id is null then raise exception 'Quest not found.'; end if;
 return v_id;
end $$;

create or replace function public.linket_owner_list_quests()
returns table(id uuid,title text,description text,target_type text,target_value integer,reward_tokens integer,enabled boolean)
language plpgsql security definer set search_path=public
as $$ begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 return query select q.id,q.title,q.description,q.target_type,q.target_value,q.reward_tokens,q.enabled from public.linket_quests q order by q.created_at desc;
end $$;

create or replace function public.linket_owner_save_achievement(p_id text,p_title text,p_description text,p_icon text,p_metric text,p_target_value integer,p_enabled boolean)
returns text language plpgsql security definer set search_path=public
as $$
begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 if length(trim(coalesce(p_id,'')))=0 or length(p_id)>60 or length(trim(coalesce(p_title,'')))=0 or p_metric not in ('wins','score','tokens','collectibles') or p_target_value<1 then raise exception 'Invalid achievement settings.'; end if;
 insert into public.linket_achievements(id,title,description,icon,metric,target_value,enabled)
 values(lower(trim(p_id)),trim(p_title),coalesce(p_description,''),coalesce(nullif(p_icon,''),'🏆'),p_metric,p_target_value,p_enabled)
 on conflict(id) do update set title=excluded.title,description=excluded.description,icon=excluded.icon,metric=excluded.metric,target_value=excluded.target_value,enabled=excluded.enabled,updated_at=now();
 return lower(trim(p_id));
end $$;

create or replace function public.linket_owner_list_achievements()
returns table(id text,title text,description text,icon text,metric text,target_value integer,enabled boolean)
language plpgsql security definer set search_path=public
as $$ begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 return query select a.id,a.title,a.description,a.icon,a.metric,a.target_value,a.enabled from public.linket_achievements a order by a.target_value,a.title;
end $$;

insert into public.linket_achievements(id,title,description,icon,metric,target_value)
values
 ('first_win','First Victory','Win your first Linket game.','🏆','wins',1),
 ('ten_wins','Rising Champion','Win 10 Linket games.','🥇','wins',10),
 ('score_1000','High Scorer','Reach a game score of 1,000.','⚡','score',1000),
 ('collector_10','Curious Collector','Own 10 collectibles.','🎒','collectibles',10),
 ('token_1000','Token Saver','Hold 1,000 tokens.','🪙','tokens',1000)
on conflict(id) do nothing;

grant usage on schema public to authenticated;
grant execute on function public.linket_claim_daily_reward() to authenticated;
grant execute on function public.linket_record_game_result(text,integer,boolean) to authenticated;
grant execute on function public.linket_get_leaderboard(text,integer) to authenticated;
grant execute on function public.linket_get_quest_board() to authenticated;
grant execute on function public.linket_get_achievement_board() to authenticated;
grant execute on function public.linket_owner_save_daily_settings(boolean,integer,integer,integer) to authenticated;
grant execute on function public.linket_owner_get_daily_settings() to authenticated;
grant execute on function public.linket_owner_save_quest(uuid,text,text,text,integer,integer,boolean) to authenticated;
grant execute on function public.linket_owner_list_quests() to authenticated;
grant execute on function public.linket_owner_save_achievement(text,text,text,text,text,integer,boolean) to authenticated;
grant execute on function public.linket_owner_list_achievements() to authenticated;
notify pgrst, 'reload schema';


create or replace function public.linket_get_daily_status()
returns table(claimed_today boolean,current_streak integer,total_claims bigint,reward_preview integer,next_claim_at timestamptz)
language plpgsql security definer set search_path=public,auth
as $$
declare v_user uuid:=auth.uid(); v_last date; v_streak integer; v_total bigint; v_enabled boolean; v_base integer; v_bonus integer; v_cap integer;
begin
 if v_user is null then raise exception 'Please sign in.'; end if;
 select enabled,base_reward,streak_bonus,max_streak_bonus into v_enabled,v_base,v_bonus,v_cap from public.linket_daily_settings where id=true;
 select last_claim_date,streak,total_claims into v_last,v_streak,v_total from public.linket_daily_claims where user_id=v_user;
 return query select (v_last=(now() at time zone 'UTC')::date),coalesce(v_streak,0),coalesce(v_total,0),
   case when coalesce(v_enabled,true) then greatest(0,v_base+least(case when v_last=(now() at time zone 'UTC')::date-1 then coalesce(v_streak,0) else 0 end,v_cap)*v_bonus) else 0 end,
   (date_trunc('day',now() at time zone 'UTC')+interval '1 day') at time zone 'UTC';
end $$;

create or replace function public.linket_get_player_progress()
returns table(tokens numeric,collectibles bigint,wins bigint,best_score bigint)
language plpgsql security definer set search_path=public,auth
as $$
begin
 if auth.uid() is null then raise exception 'Please sign in.'; end if;
 return query select coalesce(p.tokens,0)::numeric,
   coalesce((select sum(o.quantity)::bigint from public.owned_collectibles o where o.user_id=auth.uid()),0),
   coalesce((select count(*)::bigint from public.linket_game_results g where g.user_id=auth.uid() and g.won),0),
   coalesce((select max(g.score)::bigint from public.linket_game_results g where g.user_id=auth.uid()),0)
 from public.profiles p where p.id=auth.uid();
end $$;
grant execute on function public.linket_get_daily_status() to authenticated;
grant execute on function public.linket_get_player_progress() to authenticated;
notify pgrst, 'reload schema';
