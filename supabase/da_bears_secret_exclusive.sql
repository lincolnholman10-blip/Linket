-- Da Bears: owner-only Secret Exclusive. Kept outside the public catalog/inventory,
-- so it cannot drop from packs, appear in the index, be sold, or be traded normally.

CREATE TABLE IF NOT EXISTS public.linket_da_bears_holders (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL
);
ALTER TABLE public.linket_da_bears_holders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.linket_da_bears_holders FROM PUBLIC, anon, authenticated;

-- Seed the original owner with one permanent copy.
INSERT INTO public.linket_da_bears_holders(user_id,quantity,granted_by)
SELECT p.id,1,p.id FROM public.profiles p
WHERE p.is_owner=true ORDER BY p.created_at ASC LIMIT 1
ON CONFLICT(user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.linket_get_da_bears_quantity()
RETURNS integer LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public' AS $function$
DECLARE v_user_id uuid:=auth.uid(); v_quantity integer;
BEGIN
 IF v_user_id IS NULL THEN RAISE EXCEPTION 'Sign in to view your collection.'; END IF;
 SELECT h.quantity INTO v_quantity FROM public.linket_da_bears_holders h WHERE h.user_id=v_user_id;
 RETURN COALESCE(v_quantity,0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.linket_da_bears_grant(p_user_id uuid,p_quantity integer DEFAULT 1)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public' AS $function$
DECLARE v_actor uuid:=auth.uid(); v_quantity integer;
BEGIN
 IF v_actor IS NULL OR NOT public.linket_owner_dashboard_is_owner() THEN RAISE EXCEPTION 'Owner access only.'; END IF;
 IF p_user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=p_user_id) THEN RAISE EXCEPTION 'Choose a valid player.'; END IF;
 IF p_quantity IS NULL OR p_quantity<1 OR p_quantity>1000 THEN RAISE EXCEPTION 'Quantity must be between 1 and 1000.'; END IF;
 INSERT INTO public.linket_da_bears_holders(user_id,quantity,granted_by)
 VALUES(p_user_id,p_quantity,v_actor)
 ON CONFLICT(user_id) DO UPDATE SET
  quantity=public.linket_da_bears_holders.quantity+EXCLUDED.quantity,
  granted_at=now(),granted_by=v_actor
 RETURNING quantity INTO v_quantity;
 RETURN v_quantity;
END;
$function$;

-- Extend the existing reason-required owner removal RPC with Da Bears support.
CREATE OR REPLACE FUNCTION public.linket_owner_remove_collectible(
 p_user_id uuid,p_collectible_id text,p_quantity integer,p_reason text
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public' AS $function$
DECLARE
 v_actor uuid:=auth.uid(); v_reason text:=trim(coalesce(p_reason,'')); v_remaining integer; v_owned integer; v_name text;
BEGIN
 IF v_actor IS NULL OR NOT public.linket_owner_dashboard_is_owner() THEN RAISE EXCEPTION 'Owner access only.'; END IF;
 IF p_user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=p_user_id) THEN RAISE EXCEPTION 'Choose a valid player.'; END IF;
 IF p_collectible_id IS NULL OR length(trim(p_collectible_id))=0 THEN RAISE EXCEPTION 'Choose a collectible.'; END IF;
 IF p_quantity IS NULL OR p_quantity<1 OR p_quantity>1000 THEN RAISE EXCEPTION 'Quantity must be between 1 and 1000.'; END IF;
 IF length(v_reason)=0 THEN RAISE EXCEPTION 'A reason is required when removing a collectible.'; END IF;
 IF length(v_reason)>300 THEN RAISE EXCEPTION 'The reason must be 300 characters or fewer.'; END IF;

 IF p_collectible_id='__OWNER_GOD__' THEN
  SELECT h.quantity INTO v_owned FROM public.linket_owner_god_holders h WHERE h.user_id=p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This player does not own Owner God.'; END IF;
  IF v_owned<p_quantity THEN RAISE EXCEPTION 'This player only owns % Owner God. Reduce the quantity.',v_owned; END IF;
  v_remaining:=v_owned-p_quantity;
  IF v_remaining=0 THEN DELETE FROM public.linket_owner_god_holders WHERE user_id=p_user_id;
  ELSE UPDATE public.linket_owner_god_holders SET quantity=v_remaining WHERE user_id=p_user_id; END IF;
  v_name:='Owner God';
 ELSIF p_collectible_id='__DA_BEARS__' THEN
  SELECT h.quantity INTO v_owned FROM public.linket_da_bears_holders h WHERE h.user_id=p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This player does not own Da Bears.'; END IF;
  IF v_owned<p_quantity THEN RAISE EXCEPTION 'This player only owns % Da Bears. Reduce the quantity.',v_owned; END IF;
  v_remaining:=v_owned-p_quantity;
  IF v_remaining=0 THEN DELETE FROM public.linket_da_bears_holders WHERE user_id=p_user_id;
  ELSE UPDATE public.linket_da_bears_holders SET quantity=v_remaining WHERE user_id=p_user_id; END IF;
  v_name:='Da Bears';
 ELSE
  SELECT oc.quantity INTO v_owned FROM public.owned_collectibles oc
  WHERE oc.user_id=p_user_id AND oc.collectible_id=p_collectible_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This player does not own that collectible.'; END IF;
  IF v_owned<p_quantity THEN RAISE EXCEPTION 'This player only owns % of that collectible. Reduce the quantity.',v_owned; END IF;
  v_remaining:=v_owned-p_quantity;
  IF v_remaining=0 THEN DELETE FROM public.owned_collectibles WHERE user_id=p_user_id AND collectible_id=p_collectible_id;
  ELSE UPDATE public.owned_collectibles SET quantity=v_remaining WHERE user_id=p_user_id AND collectible_id=p_collectible_id; END IF;
  v_name:=p_collectible_id;
 END IF;

 IF p_user_id<>v_actor THEN
  INSERT INTO public.linket_player_notifications(user_id,title,message)
  VALUES(p_user_id,'⚠️ Collectible update from Linket',
   'The Linket owner removed '||p_quantity||' × '||v_name||' from your collection. Reason: '||v_reason);
 END IF;
 RETURN v_remaining;
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_get_da_bears_quantity() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.linket_get_da_bears_quantity() TO authenticated;
REVOKE ALL ON FUNCTION public.linket_da_bears_grant(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.linket_da_bears_grant(uuid,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.linket_owner_remove_collectible(uuid,text,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.linket_owner_remove_collectible(uuid,text,integer,text) TO authenticated;
NOTIFY pgrst,'reload schema';
