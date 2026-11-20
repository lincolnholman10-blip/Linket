-- Give every Mythical collectible its own individual ultra-rare chance.
-- The most common Mythical in each pack is capped at 0.005%; each subsequent
-- Mythical in that pack gets a strictly smaller chance. Chroma odds are not changed.
-- Remaining non-Mythical/non-Chroma odds are scaled proportionally to keep packs at 100%.

with ranked_mythicals as (
  select
    pack_cost,
    collectible_id,
    0.005::numeric / row_number() over (
      partition by pack_cost order by collectible_id
    ) as new_chance
  from public.linket_pack_odds
  where lower(rarity) = 'mythical'
    and chance_percent > 0
)
update public.linket_pack_odds o
set chance_percent = r.new_chance
from ranked_mythicals r
where o.pack_cost = r.pack_cost
  and o.collectible_id = r.collectible_id;

-- Keep the catalog's owner-dashboard drop weights individual too.
with ranked_catalog as (
  select
    collectible_id,
    0.005::numeric / row_number() over (order by collectible_id) as new_weight
  from public.linket_collectible_catalog
  where lower(rarity) = 'mythical'
    and enabled = true
)
update public.linket_collectible_catalog c
set drop_weight = r.new_weight
from ranked_catalog r
where c.collectible_id = r.collectible_id;

-- Redistribute only ordinary rarity odds. Chroma odds remain exactly as configured.
with pack_totals as (
  select
    pack_cost,
    sum(chance_percent) filter (
      where lower(rarity) in ('mythical', 'chroma') and chance_percent > 0
    ) as rare_total,
    sum(chance_percent) filter (
      where lower(rarity) not in ('mythical', 'chroma') and chance_percent > 0
    ) as ordinary_total
  from public.linket_pack_odds
  group by pack_cost
)
update public.linket_pack_odds o
set chance_percent = o.chance_percent *
  ((100 - coalesce(t.rare_total, 0)) / nullif(t.ordinary_total, 0))
from pack_totals t
where o.pack_cost = t.pack_cost
  and lower(o.rarity) not in ('mythical', 'chroma')
  and o.chance_percent > 0
  and t.ordinary_total > 0;

-- Fail rather than silently leave any configured pack with invalid odds.
do $$
declare
  v_pack record;
  v_total numeric;
begin
  for v_pack in
    select distinct pack_cost from public.linket_pack_odds
  loop
    select coalesce(sum(chance_percent), 0)
      into v_total
    from public.linket_pack_odds
    where pack_cost = v_pack.pack_cost
      and chance_percent > 0;

    if abs(v_total - 100) > 0.000001 then
      raise exception 'Pack cost % totals %, expected 100%%. Review odds before continuing.',
        v_pack.pack_cost, v_total;
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';
