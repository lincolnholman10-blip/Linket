-- Double individual Mythical drop chances while preserving their rarity order.
-- Highest Mythical: 0.01% (2x the previous 0.005%).
-- Chroma remains at 0.0001%, rarer than every Mythical.
-- Mythical rank is calculated once per collectible, then applied consistently
-- across every pack that contains that collectible.

with mythical_ids as (
  select distinct collectible_id
  from public.linket_pack_odds
  where lower(rarity) = 'mythical'
    and chance_percent > 0
),
ranked_mythicals as (
  select
    collectible_id,
    0.01::numeric / row_number() over (order by collectible_id) as new_chance
  from mythical_ids
)
update public.linket_pack_odds o
set chance_percent = r.new_chance
from ranked_mythicals r
where o.collectible_id = r.collectible_id
  and lower(o.rarity) = 'mythical';

with mythical_ids as (
  select distinct collectible_id
  from public.linket_collectible_catalog
  where lower(rarity) = 'mythical'
    and enabled = true
),
ranked_mythicals as (
  select
    collectible_id,
    0.01::numeric / row_number() over (order by collectible_id) as new_weight
  from mythical_ids
)
update public.linket_collectible_catalog c
set drop_weight = r.new_weight
from ranked_mythicals r
where c.collectible_id = r.collectible_id;

-- Keep Chroma unchanged and rarer than Mythicals.
update public.linket_pack_odds
set chance_percent = 0.0001
where lower(rarity) = 'chroma' and chance_percent > 0;

update public.linket_collectible_catalog
set drop_weight = 0.0001
where lower(rarity) = 'chroma' and enabled = true;

-- Rebalance non-Mythical/non-Chroma drops to keep every pack at 100%.
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

do $$
declare
  v_pack record;
  v_total numeric;
begin
  for v_pack in select distinct pack_cost from public.linket_pack_odds
  loop
    select coalesce(sum(chance_percent), 0)
      into v_total
    from public.linket_pack_odds
    where pack_cost = v_pack.pack_cost and chance_percent > 0;

    if abs(v_total - 100) > 0.000001 then
      raise exception 'Pack cost % totals %, expected 100%%.',
        v_pack.pack_cost, v_total;
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';
