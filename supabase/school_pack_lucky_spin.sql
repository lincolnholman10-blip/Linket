-- School Pack (225 tokens) and daily Lucky Spin.
-- Run once in the Supabase SQL Editor.

insert into public.linket_collectible_catalog
 (collectible_id,display_name,emoji,rarity,pack_name,drop_weight,enabled)
values
 ('Pencil','Pencil','✏️','Common','School Pack',35,true),
 ('Books','Books','📚','Common','School Pack',30,true),
 ('Notebook','Notebook','📓','Rare','School Pack',18,true),
 ('Backpack','Backpack','🎒','Rare','School Pack',10,true),
 ('Science Flask','Science Flask','🧪','Epic','School Pack',5,true),
 ('School Champion','School Champion','🏀','Legendary','School Pack',1.5,true),
 ('Principal''s Trophy','Principal''s Trophy','🏆','Mythical','School Pack',0.5,true)
on conflict (collectible_id) do update
set display_name=excluded.display_name,emoji=excluded.emoji,rarity=excluded.rarity,
    pack_name=excluded.pack_name,drop_weight=excluded.drop_weight,enabled=true;

insert into public.linket_pack_odds
 (pack_cost,collectible_id,pack_name,emoji,rarity,chance_percent)
values
 (225,'Pencil','School','✏️','Common',35),
 (225,'Books','School','📚','Common',30),
 (225,'Notebook','School','📓','Rare',18),
 (225,'Backpack','School','🎒','Rare',10),
 (225,'Science Flask','School','🧪','Epic',5),
 (225,'School Champion','School','🏀','Legendary',1.5),
 (225,'Principal''s Trophy','School','🏆','Mythical',0.5)
on conflict (pack_cost,collectible_id) do update
set pack_name=excluded.pack_name,emoji=excluded.emoji,rarity=excluded.rarity,
    chance_percent=excluded.chance_percent;

-- Allow the School Pack's 225-token price in the secure pack-opening function.
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
 if p_cost not in (50,75,100,125,150,175,200,225) then raise exception 'Invalid pack price.'; end if;
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

-- One Lucky Spin per account per calendar day.
create table if not exists public.linket_lucky_spin_claims (
 user_id uuid not null references public.profiles(id) on delete cascade,
 spin_date date not null default current_date,
 reward_text text not null,
 reward_tokens bigint not null default 0,
 collectible_id text,
 created_at timestamptz not null default now(),
 primary key(user_id,spin_date)
);
alter table public.linket_lucky_spin_claims enable row level security;
revoke all on public.linket_lucky_spin_claims from public,anon,authenticated;

create or replace function public.linket_lucky_spin()
returns table(reward_text text,new_balance bigint,collectible_id text)
language plpgsql security definer set search_path=public
as $function$
declare
 v_user uuid:=auth.uid();
 v_roll integer;
 v_reward bigint:=0;
 v_text text;
 v_collectible text:=null;
 v_balance bigint;
begin
 if v_user is null then raise exception 'Sign in first.'; end if;
 -- Reserve today's spin first; a duplicate claim is rejected before any reward is paid.
 insert into public.linket_lucky_spin_claims(user_id,spin_date,reward_text)
 values(v_user,current_date,'pending');
 v_roll:=floor(random()*100)::integer+1;
 if v_roll<=40 then v_reward:=50; v_text:='50 tokens';
 elsif v_roll<=70 then v_reward:=100; v_text:='100 tokens';
 elsif v_roll<=85 then v_reward:=250; v_text:='250 tokens';
 elsif v_roll<=95 then v_reward:=500; v_text:='500 tokens';
 elsif v_roll<=99 then v_reward:=1000; v_text:='1,000 tokens';
 else
   v_collectible:='Pencil';
   v_text:='Pencil collectible ✏️';
 end if;
 if v_reward>0 then
   update public.profiles set tokens=tokens+v_reward where id=v_user returning tokens into v_balance;
 else
   select tokens into v_balance from public.profiles where id=v_user;
   insert into public.owned_collectibles(user_id,collectible_id,quantity)
   values(v_user,v_collectible,1)
   on conflict(user_id,collectible_id) do update
   set quantity=public.owned_collectibles.quantity+1;
 end if;
 if v_balance is null then raise exception 'Player profile not found.'; end if;
 update public.linket_lucky_spin_claims
 set reward_text=v_text,reward_tokens=v_reward,collectible_id=v_collectible
 where user_id=v_user and spin_date=current_date;
 return query select v_text,v_balance,v_collectible;
exception
 when unique_violation then
   raise exception 'You already used your Lucky Spin today. Come back tomorrow!';
end;
$function$;
revoke all on function public.linket_lucky_spin() from public,anon;
grant execute on function public.linket_lucky_spin() to authenticated;

notify pgrst,'reload schema';
