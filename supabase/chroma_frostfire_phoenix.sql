-- Add Chroma as a supported collectible rarity and make Frostfire Phoenix a 0.001% drop.
-- Run this migration once in the Supabase SQL Editor.

do $$
declare c record;
begin
  -- Remove only rarity-related CHECK constraints so Chroma is accepted.
  for c in
    select conrelid::regclass as table_name, conname
    from pg_constraint
    where contype='c'
      and conrelid in ('public.linket_collectible_catalog'::regclass,
                       'public.linket_pack_odds'::regclass)
      and pg_get_constraintdef(oid) ilike '%rarity%'
  loop
    execute format('alter table %s drop constraint %I',c.table_name,c.conname);
  end loop;
end;
$$;

update public.linket_collectible_catalog
set rarity='Chroma',drop_weight=0.001,enabled=true
where collectible_id='Frostfire Phoenix';

update public.linket_pack_odds
set rarity='Chroma',chance_percent=0.001
where pack_cost=50 and collectible_id='Frostfire Phoenix';

-- Keep all seven Christmas Pack chances totaling exactly 100%.
update public.linket_pack_odds
set chance_percent=case collectible_id
  when 'Gingerbread Buddy' then 34.99965
  when 'Snowflake Sprite' then 34.99965
  when 'Peppermint Penguin' then 19.9998
  when 'Frosty Snowman' then 6.99993
  when 'Reindeer Dasher' then 2.949971
  when 'Santa Claus' then 0.049999
  when 'Frostfire Phoenix' then 0.001
  else chance_percent
end
where pack_cost=50
  and collectible_id in (
    'Gingerbread Buddy','Snowflake Sprite','Peppermint Penguin',
    'Frosty Snowman','Reindeer Dasher','Santa Claus','Frostfire Phoenix'
  );

notify pgrst,'reload schema';
