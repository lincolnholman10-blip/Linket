-- Allow the Owner Dashboard to grant every collectible in every pack.
-- The previous RPC only allowed the original 10 starter collectibles.

CREATE OR REPLACE FUNCTION public.linket_owner_grant_collectible(
  p_user_id uuid,
  p_collectible_id text,
  p_quantity integer DEFAULT 1
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_new_quantity integer;
BEGIN
  IF v_actor IS NULL OR NOT public.linket_owner_dashboard_is_owner() THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  IF p_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p WHERE p.id = p_user_id
  ) THEN
    RAISE EXCEPTION 'Choose a valid player.';
  END IF;

  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 1000 THEN
    RAISE EXCEPTION 'Quantity must be between 1 and 1000.';
  END IF;

  IF p_collectible_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.linket_pack_odds o
    WHERE o.collectible_id = p_collectible_id
  ) THEN
    RAISE EXCEPTION 'Unknown collectible. Refresh the Owner Dashboard and try again.';
  END IF;

  INSERT INTO public.owned_collectibles(user_id, collectible_id, quantity)
  VALUES (p_user_id, p_collectible_id, p_quantity)
  ON CONFLICT (user_id, collectible_id)
  DO UPDATE
    SET quantity = public.owned_collectibles.quantity + EXCLUDED.quantity
  RETURNING quantity INTO v_new_quantity;

  RETURN v_new_quantity;
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_owner_grant_collectible(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_owner_grant_collectible(uuid, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.linket_owner_grant_collectible(uuid, text, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
