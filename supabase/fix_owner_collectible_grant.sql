-- Fix owner collectible grants: reject NULL/invalid quantities before writing.
-- Keeps the existing owned_collectibles quantity > 0 constraint unchanged.

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
  IF v_actor IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = v_actor
      AND p.is_owner = true
  ) THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Choose a valid player.';
  END IF;

  -- NULL must be checked explicitly: SQL comparisons with NULL do not
  -- evaluate to TRUE, and could otherwise reach the table constraint.
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 1000 THEN
    RAISE EXCEPTION 'Quantity must be between 1 and 1000.';
  END IF;

  IF p_collectible_id IS NULL OR p_collectible_id NOT IN (
    'Happy Turtle','Tiny Bee','Bouncy Bunny','Robot Buddy','Frost Wolf',
    'Golden Owl','Crystal Cat','Lumi Fox','Galaxy Dragon','Starwing'
  ) THEN
    RAISE EXCEPTION 'Unknown collectible.';
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
