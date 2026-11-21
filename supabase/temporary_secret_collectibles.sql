-- Allow temporary owner grants for every Linket Secret Exclusive.
-- Temporary copies remain in linket_temporary_collectibles and expire normally.
CREATE OR REPLACE FUNCTION public.linket_owner_grant_temporary_collectible(
 p_user_id uuid,
 p_collectible_id text,
 p_quantity integer,
 p_hours integer
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
 v_expiry timestamptz;
 v_is_secret boolean;
BEGIN
 IF auth.uid() IS NULL OR NOT public.linket_owner_dashboard_is_owner() THEN
  RAISE EXCEPTION 'Owner access only.';
 END IF;
 IF p_user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=p_user_id) THEN
  RAISE EXCEPTION 'Choose a valid player.';
 END IF;
 IF p_collectible_id IS NULL OR length(trim(p_collectible_id))=0 THEN
  RAISE EXCEPTION 'Choose a collectible.';
 END IF;
 IF p_quantity IS NULL OR p_quantity<1 OR p_quantity>1000 THEN
  RAISE EXCEPTION 'Quantity must be from 1 to 1000.';
 END IF;
 IF p_hours IS NULL OR p_hours<1 OR p_hours>8760 THEN
  RAISE EXCEPTION 'Expiry must be from 1 hour to 365 days.';
 END IF;

 v_is_secret := p_collectible_id IN (
  '__OWNER_GOD__','__DA_BEARS__','__VOID_EMPEROR__','Frostfire Phoenix'
 );
 IF NOT v_is_secret AND NOT EXISTS(
  SELECT 1 FROM public.linket_collectible_catalog c
  WHERE c.collectible_id=p_collectible_id
 ) THEN
  RAISE EXCEPTION 'Choose a valid collectible.';
 END IF;

 v_expiry:=now()+make_interval(hours=>p_hours);
 INSERT INTO public.linket_temporary_collectibles
  (user_id,collectible_id,quantity,expires_at,granted_by)
 VALUES(p_user_id,p_collectible_id,p_quantity,v_expiry,auth.uid())
 ON CONFLICT(user_id,collectible_id,expires_at) DO UPDATE
 SET quantity=public.linket_temporary_collectibles.quantity+EXCLUDED.quantity,
     granted_by=auth.uid();
 RETURN v_expiry;
END;
$function$;

REVOKE ALL ON FUNCTION public.linket_owner_grant_temporary_collectible(uuid,text,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.linket_owner_grant_temporary_collectible(uuid,text,integer,integer) TO authenticated;
NOTIFY pgrst,'reload schema';
