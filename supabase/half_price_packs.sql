-- Reduce every Linket pack price by approximately 50%.
-- Fractional half-token prices are rounded to the nearest whole token.
-- Run once in the Supabase SQL Editor.

-- Move the old keys out of the way first so the new prices cannot collide
-- with another pack's existing pack_cost key.
update public.linket_pack_odds
set pack_cost = pack_cost + 1000
where pack_cost in (50,75,100,125,150,175,200,225);

update public.linket_pack_odds
set pack_cost = case pack_cost
  when 1050 then 25
  when 1075 then 38
  when 1100 then 50
  when 1125 then 63
  when 1150 then 75
  when 1175 then 88
  when 1200 then 100
  when 1225 then 113
  else pack_cost
end
where pack_cost between 1050 and 1225;

-- Update the secure pack-opening function to accept the discounted prices.
create or replace function public.linket_open_pack(p_cost integer)
returns table(collectible_id text,tokens bigint)
language plpgsql security definer set search_path=public
as $function$
#variable_conflict use_column
declare
 v_user_id uuid:=auth.uid();
 v_tokens bigint;
 v_collectible text;
 v_roll numeric;
 v_total numeric;
begin
 if v_user_id is null then raise exception 'You must be signed in.'; end if;
 if p_cost not in (25,38,50,63,75,88,100,113) then raise exception 'Invalid pack price.'; end if;
 select p.tokens into v_tokens from public.profiles p where p.id=v_user_id for update;
 if not found then raise exception 'Player profile not found.'; end if;
 if v_tokens<p_cost then raise exception 'Not enough tokens.'; end if;
 select sum(o.chance_percent) into v_total from public.linket_pack_odds o
 where o.pack_cost=p_cost and o.chance_percent>0;
 if coalesce(v_total,0)<=0 then raise exception 'No collectibles are configured for this pack.'; end if;
 v_roll:=random()*v_total;
 select chosen.collectible_id into v_collectible from (
   select o.collectible_id,sum(o.chance_percent) over(order by o.collectible_id) cumulative
   from public.linket_pack_odds o where o.pack_cost=p_cost and o.chance_percent>0
 ) chosen where chosen.cumulative>=v_roll order by chosen.cumulative limit 1;
 if v_collectible is null then raise exception 'Could not select a collectible.'; end if;
 update public.profiles p set tokens=p.tokens-p_cost where p.id=v_user_id returning p.tokens into v_tokens;
 if v_collectible='Frostfire Phoenix' then
   insert into public.linket_christmas_secret_holders(user_id,quantity)
   values(v_user_id,1)
   on conflict(user_id) do update set quantity=public.linket_christmas_secret_holders.quantity+1,granted_at=now();
 else
   insert into public.owned_collectibles(user_id,collectible_id,quantity)
   values(v_user_id,v_collectible,1)
   on conflict(user_id,collectible_id) do update
   set quantity=public.owned_collectibles.quantity+1;
 end if;
 return query select v_collectible,v_tokens;
end;
$function$;
revoke all on function public.linket_open_pack(integer) from public,anon;
grant execute on function public.linket_open_pack(integer) to authenticated;

notify pgrst,'reload schema';
