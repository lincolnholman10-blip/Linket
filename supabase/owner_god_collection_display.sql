-- Make the secret Owner God collectible visible in each holder's collection.
-- It remains separate from the normal collectible catalog and cannot be sold.

CREATE TABLE IF NOT EXISTS public.linket_owner_god_holders (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL
);

ALTER TABLE public.linket_owner_god_holders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.linket_owner_god_holders FROM PUBLIC, anon, authenticated;

-- Ensure the original owner has one permanent copy.
INSERT INTO public.linket_owner_god_holders (user_id, quantity, granted_by)
SELECT p.id, 1, p.id
FROM public.profiles p
WHERE p.is_owner = true
ORDER BY p.created_at ASC
LIMIT 1
ON CONFLICT (user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.linket_get_owner_god_quantity()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_quantity integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Sign in to view your collection.';
  END IF;

  SELECT h.quantity INTO v_quantity
  FROM public.linket_owner_god_holders h
  WHERE h.user_id = v_user_id;

  RETURN COALESCE(v_quantity, 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_get_owner_god_quantity() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.linket_get_owner_god_quantity() FROM anon;
GRANT EXECUTE ON FUNCTION public.linket_get_owner_god_quantity() TO authenticated;

NOTIFY pgrst, 'reload schema';
