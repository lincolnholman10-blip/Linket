-- Allow players to equip any collectible they own, including hidden secret collectibles.
CREATE OR REPLACE FUNCTION public.linket_set_avatar_with_secrets(p_collectible_id text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Sign in to change your avatar.';
  END IF;

  IF p_collectible_id IS NOT NULL THEN
    IF p_collectible_id = '__OWNER_GOD__' THEN
      IF NOT EXISTS (SELECT 1 FROM public.linket_owner_god_holders h WHERE h.user_id = v_user_id AND h.quantity > 0) THEN
        RAISE EXCEPTION 'You do not own Owner God.';
      END IF;
    ELSIF p_collectible_id = '__DA_BEARS__' THEN
      IF NOT EXISTS (SELECT 1 FROM public.linket_da_bears_holders h WHERE h.user_id = v_user_id AND h.quantity > 0) THEN
        RAISE EXCEPTION 'You do not own Da Bears.';
      END IF;
    ELSIF p_collectible_id = 'Frostfire Phoenix' THEN
      IF NOT EXISTS (SELECT 1 FROM public.linket_christmas_secret_holders h WHERE h.user_id = v_user_id AND h.quantity > 0) THEN
        RAISE EXCEPTION 'You do not own Frostfire Phoenix.';
      END IF;
    ELSIF NOT EXISTS (
      SELECT 1 FROM public.owned_collectibles oc
      WHERE oc.user_id = v_user_id
        AND oc.collectible_id = p_collectible_id
        AND oc.quantity > 0
    ) THEN
      RAISE EXCEPTION 'You can only equip a collectible you own.';
    END IF;
  END IF;

  UPDATE public.profiles
  SET avatar_collectible = p_collectible_id
  WHERE id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player profile not found.';
  END IF;

  RETURN COALESCE(p_collectible_id, '');
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_set_avatar_with_secrets(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.linket_set_avatar_with_secrets(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
