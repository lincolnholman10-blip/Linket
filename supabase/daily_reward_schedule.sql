-- Public-to-player read-only daily reward schedule, using the owner's current settings.
create or replace function public.linket_get_daily_reward_schedule()
returns table(day_number integer, reward_tokens integer, is_bonus_capped boolean)
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v_base integer;
  v_bonus integer;
  v_cap integer;
  v_enabled boolean;
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  select ds.base_reward, ds.streak_bonus, ds.max_streak_bonus, ds.enabled
    into v_base, v_bonus, v_cap, v_enabled
  from public.linket_daily_settings as ds
  where ds.id = true;

  return query
    select d.n,
      case when coalesce(v_enabled,true)
        then greatest(0,coalesce(v_base,50) + least(d.n-1,coalesce(v_cap,7))*coalesce(v_bonus,10))
        else 0 end,
      (d.n-1) >= coalesce(v_cap,7)
    from generate_series(1,7) as d(n);
end
$$;
grant execute on function public.linket_get_daily_reward_schedule() to authenticated;
notify pgrst, 'reload schema';
