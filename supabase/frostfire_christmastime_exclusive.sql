-- Make Frostfire Phoenix a seasonal Christmastime Exclusive.
-- Its drop chance is unchanged; only its displayed rarity/category changes.
UPDATE public.linket_collectible_catalog
SET rarity='Christmastime Exclusive'
WHERE collectible_id='Frostfire Phoenix';

UPDATE public.linket_pack_odds
SET rarity='Christmastime Exclusive'
WHERE collectible_id='Frostfire Phoenix';

NOTIFY pgrst,'reload schema';
