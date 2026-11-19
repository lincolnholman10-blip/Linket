-- Fix ambiguous total_claims reference in the daily rewards status RPC.
create or replace function public.linket_get_daily_status()
returns table(
  claimed_today boolean,
  current_streak integer,
  total_claims bigint,
  reward_preview integer,
  next_claim_at timestamptz
)
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v_user uuid := auth.uid();
  v_last date;
  v_streak integer;
  v_total bigint;
  v_enabled boolean;
  v_base integer;
  v_bonus integer;
  v_cap integer;
  v_today date := (now() at time zone 'UTC')::date;
begin
  if v_user is null then
    raise exception 'Please sign in.';
  end if;

  select ds.enabled, ds.base_reward, ds.streak_bonus, ds.max_streak_bonus
    into v_enabled, v_base, v_bonus, v_cap
  from public.linket_daily_settings as ds
  where ds.id = true;

  select dc.last_claim_date, dc.streak, dc.total_claims
    into v_last, v_streak, v_total
  from public.linket_daily_claims as dc
  where dc.user_id = v_user;

  return query
    select
      (v_last = v_today),
      coalesce(v_streak, 0),
      coalesce(v_total, 0),
      case
        when coalesce(v_enabled, true) then
          greatest(
            0,
            coalesce(v_base, 50)
            + least(
                case when v_last = v_today - 1 then coalesce(v_streak, 0) else 0 end,
                coalesce(v_cap, 7)
              ) * coalesce(v_bonus, 10)
          )
        else 0
      end,
      (date_trunc('day', now() at time zone 'UTC') + interval '1 day') at time zone 'UTC';
end
$$;

grant execute on function public.linket_get_daily_status() to authenticated;
notify pgrst, 'reload schema';
