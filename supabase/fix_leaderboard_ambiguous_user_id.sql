-- Repair ambiguous user_id references in the Linket leaderboard function.
create or replace function public.linket_get_leaderboard(p_category text default 'tokens',p_limit integer default 50)
returns table(rank bigint,user_id uuid,username text,score numeric,detail text)
language plpgsql security definer set search_path=public,auth
as $$
begin
  if p_category not in ('tokens','collectibles','wins','score') then
    raise exception 'Unknown leaderboard category.';
  end if;

  return query
  with stats as (
    select
      p.id,
      p.username,
      coalesce(p.tokens,0)::numeric as token_score,
      coalesce(c.collectible_total,0)::numeric as collectible_score,
      coalesce(g.win_total,0)::numeric as wins_score,
      coalesce(g.best_score,0)::numeric as best_score
    from public.profiles as p
    left join (
      select oc.user_id, sum(oc.quantity)::bigint as collectible_total
      from public.owned_collectibles as oc
      group by oc.user_id
    ) as c on c.user_id=p.id
    left join (
      select
        gr.user_id,
        count(*) filter (where gr.won)::bigint as win_total,
        coalesce(max(gr.score),0)::bigint as best_score
      from public.linket_game_results as gr
      group by gr.user_id
    ) as g on g.user_id=p.id
    where coalesce(p.is_banned,false)=false
  ),
  ranked as (
    select
      s.*,
      case p_category
        when 'tokens' then s.token_score
        when 'collectibles' then s.collectible_score
        when 'wins' then s.wins_score
        else s.best_score
      end as metric
    from stats as s
  )
  select
    row_number() over(order by r.metric desc,r.username asc)::bigint,
    r.id,
    r.username,
    r.metric,
    case p_category
      when 'tokens' then 'tokens'
      when 'collectibles' then 'collectibles owned'
      when 'wins' then 'game wins'
      else 'best game score'
    end
  from ranked as r
  order by r.metric desc,r.username asc
  limit greatest(1,least(coalesce(p_limit,50),100));
end
$$;

grant execute on function public.linket_get_leaderboard(text,integer) to authenticated;
notify pgrst, 'reload schema';
