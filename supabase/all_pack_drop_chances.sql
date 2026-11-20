-- Editable, database-enforced odds for every Linket pack.
create table if not exists public.linket_pack_odds (
 pack_cost integer not null,
 collectible_id text not null,
 pack_name text not null,
 emoji text not null default '✨',
 rarity text not null default 'Common',
 chance_percent numeric(10,6) not null check (chance_percent >= 0 and chance_percent <= 100),
 primary key (pack_cost, collectible_id)
);
alter table public.linket_pack_odds enable row level security;
revoke all on public.linket_pack_odds from anon, authenticated;

-- Seed the current live odds, preserving each pack's existing relative weights.
insert into public.linket_pack_odds(pack_cost,collectible_id,pack_name,emoji,rarity,chance_percent)
select pack_cost,collectible,pack_name,emoji,rarity,(weight::numeric*100/sum(weight) over(partition by pack_cost))::numeric(10,6)
from (values
(50,'Happy Turtle','Starter','🐢','Common',35000),(50,'Bouncy Bunny','Starter','🐰','Common',35000),(50,'Robot Buddy','Starter','🤖','Rare',20000),(50,'Frost Wolf','Starter','🐺','Epic',7000),(50,'Golden Owl','Starter','🦉','Legendary',2000),(50,'Starwing','Starter','🪽','Mythical',70),
(100,'Tiny Bee','Rainbow','🐝','Common',35000),(100,'Bouncy Bunny','Rainbow','🐰','Common',35000),(100,'Robot Buddy','Rainbow','🤖','Rare',20000),(100,'Crystal Cat','Rainbow','🐱','Legendary',2000),(100,'Lumi Fox','Rainbow','🦊','Mythical',10),
(150,'Robot Buddy','Galaxy','🤖','Common',70000),(150,'Frost Wolf','Galaxy','🐺','Rare',20000),(150,'Crystal Cat','Galaxy','🐱','Epic',2000),(150,'Galaxy Dragon','Galaxy','🐉','Mythical',5),(150,'Starwing','Galaxy','🪽','Mythical',5),
(75,'Seashell Snail','Ocean','🐌','Common',35000),(75,'Surfer Seal','Ocean','🦭','Common',35000),(75,'Crab Pal','Ocean','🦀','Rare',20000),(75,'Coral Turtle','Ocean','🐢','Epic',7000),(75,'Pearl Dolphin','Ocean','🐬','Legendary',2950),(75,'Tidal Phoenix','Ocean','🦚','Mythical',50),
(125,'Moon Moth','Space','🦋','Common',35000),(125,'Astro Pup','Space','🐶','Common',35000),(125,'Comet Cat','Space','🐱','Rare',20000),(125,'Nebula Fox','Space','🦊','Epic',7000),(125,'Solar Dragon','Space','🐉','Legendary',2950),(125,'Void Unicorn','Space','🦄','Mythical',50),
(175,'Puppy Pal','Pets','🐶','Common',35000),(175,'Corgi Buddy','Pets','🐕','Common',35000),(175,'Dalmatian Dash','Pets','🐾','Rare',20000),(175,'Shiba Star','Pets','🐕','Epic',7000),(175,'Golden Retriever','Pets','🦮','Legendary',2950),(175,'Cosmic Wolf','Pets','🐺','Mythical',50),
(200,'Rookie Hooper','Sports','🏀','Common',40000),(200,'Goal Getter','Sports','⚽','Common',30000),(200,'Court Captain','Sports','🏀','Rare',20000),(200,'Grand Slam Star','Sports','⚾','Epic',7000),(200,'Championship MVP','Sports','🏆','Legendary',2995),(200,'Mason Plumlee','Sports','🗿','Mythical',5)
) as seed(pack_cost,collectible,pack_name,emoji,rarity,weight)
on conflict(pack_cost,collectible_id) do nothing;

create or replace function public.linket_owner_list_pack_odds()
returns table(pack_cost integer,pack_name text,collectible_id text,emoji text,rarity text,chance_percent numeric)
language plpgsql security definer set search_path=public
as $$
begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 return query select o.pack_cost,o.pack_name,o.collectible_id,o.emoji,o.rarity,o.chance_percent
 from public.linket_pack_odds o order by o.pack_cost,o.chance_percent desc,o.collectible_id;
end $$;

create or replace function public.linket_owner_set_pack_odds(p_pack_cost integer,p_collectible_id text,p_chance_percent numeric)
returns void language plpgsql security definer set search_path=public
as $$
begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 if p_chance_percent is null or p_chance_percent<0 or p_chance_percent>100 then raise exception 'Chance must be between 0 and 100.'; end if;
 update public.linket_pack_odds set chance_percent=p_chance_percent
 where pack_cost=p_pack_cost and collectible_id=p_collectible_id;
 if not found then raise exception 'Collectible odds entry not found.'; end if;
end $$;

create or replace function public.linket_open_pack(p_cost integer)
returns table(collectible_id text,tokens bigint)
language plpgsql security definer set search_path=public
as $function$
#variable_conflict use_column
declare v_user_id uuid:=auth.uid(); v_tokens bigint; v_collectible text; v_roll numeric; v_total numeric;
begin
 if v_user_id is null then raise exception 'You must be signed in.'; end if;
 if p_cost not in (50,75,100,125,150,175,200) then raise exception 'Invalid pack price.'; end if;
 select p.tokens into v_tokens from public.profiles p where p.id=v_user_id for update;
 if not found then raise exception 'Player profile not found.'; end if;
 if v_tokens<p_cost then raise exception 'Not enough tokens.'; end if;
 update public.profiles p set tokens=p.tokens-p_cost where p.id=v_user_id returning p.tokens into v_tokens;
 select sum(o.chance_percent) into v_total from public.linket_pack_odds o where o.pack_cost=p_cost and o.chance_percent>0;
 if coalesce(v_total,0)<=0 then raise exception 'No collectibles are configured for this pack.'; end if;
 v_roll:=random()*v_total;
 select chosen.collectible_id into v_collectible from (
   select o.collectible_id,sum(o.chance_percent) over(order by o.collectible_id) as cumulative
   from public.linket_pack_odds o where o.pack_cost=p_cost and o.chance_percent>0
 ) chosen where chosen.cumulative>=v_roll order by chosen.cumulative limit 1;
 if v_collectible is null then raise exception 'Could not select a collectible.'; end if;
 insert into public.owned_collectibles(user_id,collectible_id,quantity) values(v_user_id,v_collectible,1)
 on conflict(user_id,collectible_id) do update set quantity=public.owned_collectibles.quantity+1;
 return query select v_collectible,v_tokens;
end;
$function$;

grant execute on function public.linket_owner_list_pack_odds() to authenticated;
grant execute on function public.linket_owner_set_pack_odds(integer,text,numeric) to authenticated;
grant execute on function public.linket_open_pack(integer) to authenticated;
notify pgrst,'reload schema';
