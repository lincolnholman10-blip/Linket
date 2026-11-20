-- Change Frostfire Phoenix from Chroma to Mythical while preserving its rainbow Chroma visual styling in the app.
UPDATE public.linket_collectible_catalog
SET rarity='Mythical'
WHERE collectible_id='Frostfire Phoenix';

UPDATE public.linket_pack_odds
SET rarity='Mythical'
WHERE collectible_id='Frostfire Phoenix';

NOTIFY pgrst,'reload schema';
