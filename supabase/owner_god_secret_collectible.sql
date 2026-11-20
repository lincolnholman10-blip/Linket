-- Secret collectible: Owner God
-- This collectible is stored separately from the public catalog and inventory,
-- so it never appears in packs, the index, or a player's normal collection.

CREATE TABLE IF NOT EXISTS public.linket_owner_god_holders (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL
);

ALTER TABLE public.linket_owner_god_holders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.linket_owner_god_holders FROM PUBLIC, anon, authenticated;

-- Give the original/primary owner the exclusive collectible automatically.
INSERT INTO public.linket_owner_god_holders (user_id, quantity, granted_by)
SELECT p.id, 1, p.id
FROM public.profiles p
WHERE p.is_owner = true
ORDER BY p.created_at ASC
LIMIT 1
ON CONFLICT (user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.linket_owner_god_grant(
  p_user_id uuid,
  p_quantity integer DEFAULT 1
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_quantity integer;
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

  INSERT INTO public.linket_owner_god_holders (user_id, quantity, granted_by)
  VALUES (p_user_id, p_quantity, v_actor)
  ON CONFLICT (user_id)
  DO UPDATE SET
    quantity = public.linket_owner_god_holders.quantity + EXCLUDED.quantity,
    granted_at = now(),
    granted_by = v_actor
  RETURNING quantity INTO v_quantity;

  RETURN v_quantity;
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_owner_god_grant(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_owner_god_grant(uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.linket_owner_god_grant(uuid, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
