-- Make every Mythical collectible ultra-rare: 0.005% (1 in 20,000) per item.
-- Chroma odds remain unchanged. Other drops are scaled proportionally so each pack
-- continues to total exactly 100%.

update public.linket_pack_odds
set chance_percent = 0.005
where lower(rarity) = 'mythical'
  and chance_percent > 0;

with pack_totals as (
  select
    pack_cost,
    sum(chance_percent) filter (where lower(rarity) = 'mythical' and chance_percent > 0) as mythical_total,
    sum(chance_percent) filter (where lower(rarity) = 'chroma' and chance_percent > 0) as chroma_total,
    sum(chance_percent) filter (
      where lower(rarity) not in ('mythical', 'chroma') and chance_percent > 0
    ) as ordinary_total
  from public.linket_pack_odds
  group by pack_cost
)
update public.linket_pack_odds o
set chance_percent = o.chance_percent *
  ((100 - coalesce(t.mythical_total, 0) - coalesce(t.chroma_total, 0)) / t.ordinary_total)
from pack_totals t
where o.pack_cost = t.pack_cost
  and lower(o.rarity) not in ('mythical', 'chroma')
  and o.chance_percent > 0
  and coalesce(t.ordinary_total, 0) > 0;

-- Keep the owner collectible catalog's displayed Mythical drop weight consistent.
update public.linket_collectible_catalog
set drop_weight = 0.005
where lower(rarity) = 'mythical';

-- Verify every configured pack still totals 100%.
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
      raise exception 'Pack cost % totals %, expected 100%%', v_pack.pack_cost, v_total;
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';
