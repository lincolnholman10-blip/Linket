-- Make Owner Dashboard "Unlock every collectible" include every pack,
-- including School Pack, plus the protected secret collectibles.
CREATE OR REPLACE FUNCTION public.linket_owner_unlock_all()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_count integer := 0;
  v_rows integer := 0;
BEGIN
  IF v_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_user_id AND p.is_owner = true
  ) THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  -- Pull from the live catalog and pack odds so new packs (including School)
  -- are automatically included without another hard-coded list.
  INSERT INTO public.owned_collectibles(user_id, collectible_id, quantity)
  SELECT v_user_id, all_items.collectible_id, 1
  FROM (
    SELECT c.collectible_id
    FROM public.linket_collectible_catalog c
    WHERE c.collectible_id <> 'Frostfire Phoenix'
    UNION
    SELECT o.collectible_id
    FROM public.linket_pack_odds o
    WHERE o.collectible_id <> 'Frostfire Phoenix'
  ) AS all_items
  WHERE all_items.collectible_id IS NOT NULL
  ON CONFLICT (user_id, collectible_id) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  -- These special collectibles are deliberately stored outside normal inventory.
  INSERT INTO public.linket_christmas_secret_holders(user_id, quantity)
  VALUES (v_user_id, 1)
  ON CONFLICT (user_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  INSERT INTO public.linket_owner_god_holders(user_id, quantity, granted_by)
  VALUES (v_user_id, 1, v_user_id)
  ON CONFLICT (user_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  INSERT INTO public.linket_da_bears_holders(user_id, quantity, granted_by)
  VALUES (v_user_id, 1, v_user_id)
  ON CONFLICT (user_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_owner_unlock_all() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.linket_owner_unlock_all() TO authenticated;
NOTIFY pgrst, 'reload schema';
