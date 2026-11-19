-- Fix owner player list after profiles.tokens was upgraded to numeric(20,0).
-- The function's TABLE return type must match the new tokens column type.

DROP FUNCTION IF EXISTS public.linket_owner_list_players();

CREATE FUNCTION public.linket_owner_list_players()
RETURNS TABLE(
  player_id uuid,
  username text,
  tokens numeric,
  is_owner boolean,
  created_at timestamp with time zone,
  collectible_count bigint,
  is_banned boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.is_owner = true
  ) THEN
    RAISE EXCEPTION 'Owner access only.';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.username,
    p.tokens::numeric,
    p.is_owner,
    p.created_at,
    COUNT(DISTINCT oc.collectible_id)::bigint,
    p.is_banned
  FROM public.profiles p
  LEFT JOIN public.owned_collectibles oc ON oc.user_id = p.id
  GROUP BY
    p.id,
    p.username,
    p.tokens,
    p.is_owner,
    p.created_at,
    p.is_banned
  ORDER BY p.created_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_owner_list_players() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_owner_list_players() FROM anon;
GRANT EXECUTE ON FUNCTION public.linket_owner_list_players() TO authenticated;
