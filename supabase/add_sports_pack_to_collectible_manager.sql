-- Add the six Sports Pack collectibles to the Owner Dashboard collectible catalog.
-- Existing catalog edits are preserved; only missing Sports entries are inserted.

insert into public.linket_collectible_catalog
  (collectible_id, display_name, emoji, rarity, pack_name, drop_weight, enabled)
values
  ('Rookie Hooper', 'Rookie Hooper', '🏀', 'Common', 'Sports Pack', 40000, true),
  ('Goal Getter', 'Goal Getter', '⚽', 'Common', 'Sports Pack', 30000, true),
  ('Court Captain', 'Court Captain', '🏀', 'Rare', 'Sports Pack', 20000, true),
  ('Grand Slam Star', 'Grand Slam Star', '⚾', 'Epic', 'Sports Pack', 7000, true),
  ('Championship MVP', 'Championship MVP', '🏆', 'Legendary', 'Sports Pack', 2995, true),
  ('Mason Plumlee', 'Mason Plumlee', '🗿', 'Mythical', 'Sports Pack', 5, true)
on conflict (collectible_id) do nothing;

notify pgrst, 'reload schema';
