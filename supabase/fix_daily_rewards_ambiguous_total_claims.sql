-- Fix ambiguous total_claims output-column reference in daily reward claim RPC.
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
  if v_user is null then
    raise exception 'Please sign in to claim your daily reward.';
  end if;

  select ds.enabled,ds.base_reward,ds.streak_bonus,ds.max_streak_bonus
    into v_enabled,v_base,v_bonus,v_cap
  from public.linket_daily_settings as ds
  where ds.id=true;

  if not coalesce(v_enabled,true) then
    return query
      select false,0,0,0::bigint,
        (date_trunc('day',now() at time zone 'UTC') + interval '1 day') at time zone 'UTC',
        'Daily rewards are temporarily disabled.';
    return;
  end if;

  insert into public.linket_daily_claims(user_id,last_claim_date,streak,total_claims)
    values(v_user,v_today-1,0,0)
    on conflict(user_id) do nothing;

  select dc.last_claim_date,dc.streak,dc.total_claims
    into v_last,v_streak,v_total
  from public.linket_daily_claims as dc
  where dc.user_id=v_user
  for update;

  if v_last=v_today then
    return query
      select false,0,v_streak,v_total,
        (date_trunc('day',now() at time zone 'UTC') + interval '1 day') at time zone 'UTC',
        'You already claimed today. Come back tomorrow!';
    return;
  end if;

  if v_last=v_today-1 then
    v_streak:=v_streak+1;
  else
    v_streak:=1;
  end if;

  v_total:=v_total+1;
  v_reward:=greatest(0,v_base + least(v_streak-1,v_cap)*v_bonus);

  update public.linket_daily_claims as dc
    set last_claim_date=v_today,
        streak=v_streak,
        total_claims=v_total,
        updated_at=now()
  where dc.user_id=v_user;

  update public.profiles as p
    set tokens=coalesce(p.tokens,0)+v_reward
  where p.id=v_user;

  return query
    select true,v_reward,v_streak,v_total,
      (date_trunc('day',now() at time zone 'UTC') + interval '1 day') at time zone 'UTC',
      'Daily reward claimed!';
end
$$;

grant execute on function public.linket_claim_daily_reward() to authenticated;
notify pgrst, 'reload schema';
