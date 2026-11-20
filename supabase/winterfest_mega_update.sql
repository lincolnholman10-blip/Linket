-- Linket Winterfest Mega Update
-- Secret Christmas drop, one-time completion bonus, temporary collectibles,
-- and claimable owner-configured live-event rewards.

-- 1) A hidden, unsellable, untradeable Christmas secret collectible.
create table if not exists public.linket_christmas_secret_holders (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  quantity integer not null default 1 check (quantity > 0),
  granted_at timestamptz not null default now()
);
alter table public.linket_christmas_secret_holders enable row level security;
revoke all on public.linket_christmas_secret_holders from public, anon, authenticated;

insert into public.linket_collectible_catalog
  (collectible_id,display_name,emoji,rarity,pack_name,drop_weight,enabled)
values
  ('Frostfire Phoenix','Frostfire Phoenix','🔥','Mythical','Christmas Pack',0.01,true)
on conflict (collectible_id) do update
set display_name=excluded.display_name,emoji=excluded.emoji,rarity=excluded.rarity,
    pack_name=excluded.pack_name,drop_weight=excluded.drop_weight,enabled=true;

-- Ensure all six regular Christmas drops exist even if the installer button was never used.
insert into public.linket_collectible_catalog
 (collectible_id,display_name,emoji,rarity,pack_name,drop_weight,enabled)
values
 ('Gingerbread Buddy','Gingerbread Buddy','🍪','Common','Christmas Pack',35,true),
 ('Snowflake Sprite','Snowflake Sprite','❄️','Common','Christmas Pack',35,true),
 ('Peppermint Penguin','Peppermint Penguin','🐧','Rare','Christmas Pack',20,true),
 ('Frosty Snowman','Frosty Snowman','☃️','Epic','Christmas Pack',7,true),
 ('Reindeer Dasher','Reindeer Dasher','🦌','Legendary','Christmas Pack',2.95,true),
 ('Santa Claus','Santa Claus','🎅','Mythical','Christmas Pack',0.05,true)
on conflict (collectible_id) do update
set display_name=excluded.display_name,emoji=excluded.emoji,rarity=excluded.rarity,
    pack_name=excluded.pack_name,enabled=true;

insert into public.linket_pack_odds(pack_cost,collectible_id,pack_name,emoji,rarity,chance_percent)
values
 (50,'Gingerbread Buddy','Christmas','🍪','Common',35),
 (50,'Snowflake Sprite','Christmas','❄️','Common',35),
 (50,'Peppermint Penguin','Christmas','🐧','Rare',20),
 (50,'Frosty Snowman','Christmas','☃️','Epic',7),
 (50,'Reindeer Dasher','Christmas','🦌','Legendary',2.95),
 (50,'Santa Claus','Christmas','🎅','Mythical',0.05)
on conflict(pack_cost,collectible_id) do nothing;

-- Reserve exactly 0.01% for the secret and scale the six normal Christmas drops to 99.99%.
update public.linket_pack_odds
set chance_percent=case collectible_id
 when 'Gingerbread Buddy' then 34.9965
 when 'Snowflake Sprite' then 34.9965
 when 'Peppermint Penguin' then 19.998
 when 'Frosty Snowman' then 6.9993
 when 'Reindeer Dasher' then 2.949705
 when 'Santa Claus' then 0.049995
 else chance_percent end
where pack_cost=50 and collectible_id in
 ('Gingerbread Buddy','Snowflake Sprite','Peppermint Penguin','Frosty Snowman','Reindeer Dasher','Santa Claus');
insert into public.linket_pack_odds(pack_cost,collectible_id,pack_name,emoji,rarity,chance_percent)
values(50,'Frostfire Phoenix','Christmas','🔥','Mythical',0.01)
on conflict(pack_cost,collectible_id) do update
set pack_name=excluded.pack_name,emoji=excluded.emoji,rarity=excluded.rarity,chance_percent=excluded.chance_percent;


create or replace function public.linket_owner_grant_christmas_secret(p_user_id uuid,p_quantity integer default 1)
returns integer language plpgsql security definer set search_path=public
as $$
declare v_qty integer;
begin
 if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access only.'; end if;
 if not exists(select 1 from public.profiles p where p.id=p_user_id) then raise exception 'Choose a valid player.'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>1000 then raise exception 'Quantity must be from 1 to 1000.'; end if;
 insert into public.linket_christmas_secret_holders(user_id,quantity)
 values(p_user_id,p_quantity)
 on conflict(user_id) do update set quantity=public.linket_christmas_secret_holders.quantity+excluded.quantity,granted_at=now()
 returning quantity into v_qty;
 return v_qty;
end;
$$;

create or replace function public.linket_get_christmas_secret_quantity()
returns integer language plpgsql stable security definer set search_path=public
as $$
declare v_qty integer;
begin
 if auth.uid() is null then raise exception 'Sign in to view your collection.'; end if;
 select h.quantity into v_qty from public.linket_christmas_secret_holders h where h.user_id=auth.uid();
 return coalesce(v_qty,0);
end;
$$;

-- Replace pack opening so the hidden collectible is stored separately from normal inventory.
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
 if p_cost not in (50,75,100,125,150,175,200) then raise exception 'Invalid pack price.'; end if;
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

-- 2) One-time 5,000-token reward for owning all six regular Christmas drops.
create table if not exists public.linket_christmas_collection_claims (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 claimed_at timestamptz not null default now(),
 reward_tokens bigint not null default 5000
);
alter table public.linket_christmas_collection_claims enable row level security;
revoke all on public.linket_christmas_collection_claims from public,anon,authenticated;

create or replace function public.linket_claim_christmas_collection_bonus()
returns bigint language plpgsql security definer set search_path=public
as $$
declare v_user uuid:=auth.uid(); v_balance bigint;
begin
 if v_user is null then raise exception 'Sign in first.'; end if;
 if not exists(select 1 from public.owned_collectibles oc where oc.user_id=v_user and oc.collectible_id='Gingerbread Buddy' and oc.quantity>0)
 or not exists(select 1 from public.owned_collectibles oc where oc.user_id=v_user and oc.collectible_id='Snowflake Sprite' and oc.quantity>0)
 or not exists(select 1 from public.owned_collectibles oc where oc.user_id=v_user and oc.collectible_id='Peppermint Penguin' and oc.quantity>0)
 or not exists(select 1 from public.owned_collectibles oc where oc.user_id=v_user and oc.collectible_id='Frosty Snowman' and oc.quantity>0)
 or not exists(select 1 from public.owned_collectibles oc where oc.user_id=v_user and oc.collectible_id='Reindeer Dasher' and oc.quantity>0)
 or not exists(select 1 from public.owned_collectibles oc where oc.user_id=v_user and oc.collectible_id='Santa Claus' and oc.quantity>0)
 then raise exception 'Collect all six regular Christmas collectibles first.'; end if;
 insert into public.linket_christmas_collection_claims(user_id) values(v_user)
 on conflict(user_id) do nothing;
 if not found then raise exception 'You already claimed the Christmas collection bonus.'; end if;
 update public.profiles p set tokens=p.tokens+5000 where p.id=v_user returning p.tokens into v_balance;
 return v_balance;
end;
$$;

-- 11) Temporary collectible inventory. Expired copies are never returned to players.
create table if not exists public.linket_temporary_collectibles (
 user_id uuid not null references public.profiles(id) on delete cascade,
 collectible_id text not null,
 quantity integer not null default 1 check(quantity>0),
 expires_at timestamptz not null,
 granted_at timestamptz not null default now(),
 granted_by uuid references public.profiles(id) on delete set null,
 primary key(user_id,collectible_id,expires_at)
);
alter table public.linket_temporary_collectibles enable row level security;
revoke all on public.linket_temporary_collectibles from public,anon,authenticated;

create or replace function public.linket_player_list_temporary_collectibles()
returns table(collectible_id text,quantity integer,expires_at timestamptz)
language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 delete from public.linket_temporary_collectibles t where t.expires_at<=now();
 return query select t.collectible_id,t.quantity,t.expires_at
 from public.linket_temporary_collectibles t
 where t.user_id=auth.uid() and t.expires_at>now()
 order by t.expires_at;
end;
$$;

create or replace function public.linket_owner_grant_temporary_collectible(
 p_user_id uuid,p_collectible_id text,p_quantity integer,p_hours integer
)
returns timestamptz language plpgsql security definer set search_path=public
as $$
declare v_expiry timestamptz;
begin
 if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access only.'; end if;
 if not exists(select 1 from public.profiles p where p.id=p_user_id) then raise exception 'Choose a valid player.'; end if;
 if not exists(select 1 from public.linket_collectible_catalog c where c.collectible_id=p_collectible_id) then raise exception 'Choose a catalog collectible.'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>1000 then raise exception 'Quantity must be from 1 to 1000.'; end if;
 if p_hours is null or p_hours<1 or p_hours>8760 then raise exception 'Expiry must be from 1 hour to 365 days.'; end if;
 v_expiry:=now()+make_interval(hours=>p_hours);
 insert into public.linket_temporary_collectibles(user_id,collectible_id,quantity,expires_at,granted_by)
 values(p_user_id,p_collectible_id,p_quantity,v_expiry,auth.uid())
 on conflict(user_id,collectible_id,expires_at) do update
 set quantity=public.linket_temporary_collectibles.quantity+excluded.quantity,granted_by=auth.uid();
 return v_expiry;
end;
$$;

-- 12) Owner-configured live-event collectible rewards, claimed once by each player while active.
alter table public.linket_live_events
 add column if not exists reward_collectible_id text,
 add column if not exists temporary_reward_hours integer not null default 0;

create table if not exists public.linket_live_event_claims (
 event_id uuid not null references public.linket_live_events(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 claimed_at timestamptz not null default now(),
 primary key(event_id,user_id)
);
alter table public.linket_live_event_claims enable row level security;
revoke all on public.linket_live_event_claims from public,anon,authenticated;

create or replace function public.linket_owner_set_event_collectible_reward(
 p_event_id uuid,p_collectible_id text,p_temporary_hours integer
)
returns void language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access only.'; end if;
 if p_temporary_hours is null or p_temporary_hours<0 or p_temporary_hours>8760 then raise exception 'Temporary duration must be between 0 and 8760 hours.'; end if;
 if p_collectible_id is not null and not exists(select 1 from public.linket_collectible_catalog c where c.collectible_id=p_collectible_id) then raise exception 'Choose a valid catalog collectible.'; end if;
 if p_collectible_id is null and p_temporary_hours<>0 then raise exception 'Choose a collectible before setting its duration.'; end if;
 update public.linket_live_events
 set reward_collectible_id=p_collectible_id,temporary_reward_hours=p_temporary_hours,updated_at=now()
 where id=p_event_id;
 if not found then raise exception 'Event not found.'; end if;
end;
$$;



create or replace function public.linket_owner_list_event_rewards()
returns table(event_id uuid,reward_collectible_id text,temporary_reward_hours integer)
language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 return query select e.id,e.reward_collectible_id,e.temporary_reward_hours from public.linket_live_events e;
end;
$$;

create or replace function public.linket_get_christmas_bonus_claimed()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.linket_christmas_collection_claims c where c.user_id=auth.uid()); $$;

create or replace function public.linket_player_list_active_events()
returns table(id uuid,title text,message text,reward_tokens integer,reward_collectible_id text,temporary_reward_hours integer,claimed boolean,ends_at timestamptz)
language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 return query
 select e.id,e.title,e.message,e.reward_tokens,e.reward_collectible_id,e.temporary_reward_hours,
        exists(select 1 from public.linket_live_event_claims c where c.event_id=e.id and c.user_id=auth.uid()),
        e.ends_at
 from public.linket_live_events e
 where e.status='active' and (e.starts_at is null or e.starts_at<=now())
   and (e.ends_at is null or e.ends_at>now())
 order by e.starts_at nulls first,e.created_at desc;
end;
$$;

create or replace function public.linket_player_claim_event_reward(p_event_id uuid)
returns table(tokens bigint,collectible_id text,expires_at timestamptz)
language plpgsql security definer set search_path=public
as $$
declare v_user uuid:=auth.uid(); v_event public.linket_live_events%rowtype; v_balance bigint; v_expiry timestamptz;
begin
 if v_user is null then raise exception 'Sign in first.'; end if;
 select e.* into v_event from public.linket_live_events e where e.id=p_event_id for update;
 if not found then raise exception 'Event not found.'; end if;
 if v_event.status<>'active' or (v_event.starts_at is not null and v_event.starts_at>now()) or (v_event.ends_at is not null and v_event.ends_at<=now()) then
  raise exception 'This event reward is not currently available.';
 end if;
 insert into public.linket_live_event_claims(event_id,user_id) values(p_event_id,v_user)
 on conflict(event_id,user_id) do nothing;
 if not found then raise exception 'You already claimed this event reward.'; end if;
 update public.profiles p set tokens=p.tokens+v_event.reward_tokens where p.id=v_user returning p.tokens into v_balance;
 if v_event.reward_collectible_id is not null then
  if v_event.temporary_reward_hours>0 then
   v_expiry:=now()+make_interval(hours=>v_event.temporary_reward_hours);
   insert into public.linket_temporary_collectibles(user_id,collectible_id,quantity,expires_at,granted_by)
   values(v_user,v_event.reward_collectible_id,1,v_expiry,v_event.created_by)
   on conflict(user_id,collectible_id,expires_at) do update
   set quantity=public.linket_temporary_collectibles.quantity+1;
  elsif v_event.reward_collectible_id='Frostfire Phoenix' then
   insert into public.linket_christmas_secret_holders(user_id,quantity)
   values(v_user,1)
   on conflict(user_id) do update
   set quantity=public.linket_christmas_secret_holders.quantity+1,granted_at=now();
  else
   insert into public.owned_collectibles(user_id,collectible_id,quantity)
   values(v_user,v_event.reward_collectible_id,1)
   on conflict(user_id,collectible_id) do update
   set quantity=public.owned_collectibles.quantity+1;
  end if;
 end if;
 return query select coalesce(v_balance,0),v_event.reward_collectible_id,v_expiry;
end;
$$;


-- Extend the existing owner removal RPC so the secret stays manageable by the owner.
create or replace function public.linket_owner_remove_collectible(
 p_user_id uuid,p_collectible_id text,p_quantity integer,p_reason text
)
returns integer language plpgsql security definer set search_path=public
as $function$
declare
 v_actor uuid:=auth.uid(); v_reason text:=trim(coalesce(p_reason,'')); v_remaining integer; v_owned integer; v_name text;
begin
 if v_actor is null or not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access only.'; end if;
 if p_user_id is null or not exists(select 1 from public.profiles p where p.id=p_user_id) then raise exception 'Choose a valid player.'; end if;
 if p_collectible_id is null or length(trim(p_collectible_id))=0 then raise exception 'Choose a collectible.'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>1000 then raise exception 'Quantity must be between 1 and 1000.'; end if;
 if length(v_reason)=0 then raise exception 'A reason is required when removing a collectible.'; end if;
 if length(v_reason)>300 then raise exception 'The reason must be 300 characters or fewer.'; end if;
 if p_collectible_id='__OWNER_GOD__' then
  select h.quantity into v_owned from public.linket_owner_god_holders h where h.user_id=p_user_id for update;
  if not found then raise exception 'This player does not own Owner God.'; end if;
  if v_owned<p_quantity then raise exception 'This player only owns % Owner God. Reduce the quantity.',v_owned; end if;
  v_remaining:=v_owned-p_quantity;
  if v_remaining=0 then delete from public.linket_owner_god_holders where user_id=p_user_id;
  else update public.linket_owner_god_holders set quantity=v_remaining where user_id=p_user_id; end if;
  v_name:='Owner God';
 elsif p_collectible_id='__DA_BEARS__' then
  select h.quantity into v_owned from public.linket_da_bears_holders h where h.user_id=p_user_id for update;
  if not found then raise exception 'This player does not own Da Bears.'; end if;
  if v_owned<p_quantity then raise exception 'This player only owns % Da Bears. Reduce the quantity.',v_owned; end if;
  v_remaining:=v_owned-p_quantity;
  if v_remaining=0 then delete from public.linket_da_bears_holders where user_id=p_user_id;
  else update public.linket_da_bears_holders set quantity=v_remaining where user_id=p_user_id; end if;
  v_name:='Da Bears';
 elsif p_collectible_id='Frostfire Phoenix' then
  select h.quantity into v_owned from public.linket_christmas_secret_holders h where h.user_id=p_user_id for update;
  if not found then raise exception 'This player does not own Frostfire Phoenix.'; end if;
  if v_owned<p_quantity then raise exception 'This player only owns % Frostfire Phoenix. Reduce the quantity.',v_owned; end if;
  v_remaining:=v_owned-p_quantity;
  if v_remaining=0 then delete from public.linket_christmas_secret_holders where user_id=p_user_id;
  else update public.linket_christmas_secret_holders set quantity=v_remaining,granted_at=now() where user_id=p_user_id; end if;
  v_name:='Frostfire Phoenix';
 else
  select oc.quantity into v_owned from public.owned_collectibles oc where oc.user_id=p_user_id and oc.collectible_id=p_collectible_id for update;
  if not found then raise exception 'This player does not own that collectible.'; end if;
  if v_owned<p_quantity then raise exception 'This player only owns % of that collectible. Reduce the quantity.',v_owned; end if;
  v_remaining:=v_owned-p_quantity;
  if v_remaining=0 then delete from public.owned_collectibles where user_id=p_user_id and collectible_id=p_collectible_id;
  else update public.owned_collectibles set quantity=v_remaining where user_id=p_user_id and collectible_id=p_collectible_id; end if;
  v_name:=p_collectible_id;
 end if;
 if p_user_id<>v_actor then
  insert into public.linket_player_notifications(user_id,title,message)
  values(p_user_id,'⚠️ Collectible update from Linket','The Linket owner removed '||p_quantity||' × '||v_name||' from your collection. Reason: '||v_reason);
 end if;
 return v_remaining;
end;
$function$;

revoke all on function public.linket_get_christmas_secret_quantity() from public,anon;
revoke all on function public.linket_owner_grant_christmas_secret(uuid,integer) from public,anon;
revoke all on function public.linket_claim_christmas_collection_bonus() from public,anon;
revoke all on function public.linket_player_list_temporary_collectibles() from public,anon;
revoke all on function public.linket_owner_grant_temporary_collectible(uuid,text,integer,integer) from public,anon;
revoke all on function public.linket_owner_set_event_collectible_reward(uuid,text,integer) from public,anon;
revoke all on function public.linket_player_claim_event_reward(uuid) from public,anon;
revoke all on function public.linket_player_list_active_events() from public,anon;
revoke all on function public.linket_owner_list_event_rewards() from public,anon;
revoke all on function public.linket_get_christmas_bonus_claimed() from public,anon;
grant execute on function public.linket_get_christmas_secret_quantity() to authenticated;
grant execute on function public.linket_owner_grant_christmas_secret(uuid,integer) to authenticated;
grant execute on function public.linket_claim_christmas_collection_bonus() to authenticated;
grant execute on function public.linket_player_list_temporary_collectibles() to authenticated;
grant execute on function public.linket_owner_grant_temporary_collectible(uuid,text,integer,integer) to authenticated;
grant execute on function public.linket_owner_set_event_collectible_reward(uuid,text,integer) to authenticated;
grant execute on function public.linket_player_claim_event_reward(uuid) to authenticated;
grant execute on function public.linket_player_list_active_events() to authenticated;
grant execute on function public.linket_owner_list_event_rewards() to authenticated;
grant execute on function public.linket_get_christmas_bonus_claimed() to authenticated;
grant execute on function public.linket_open_pack(integer) to authenticated;
notify pgrst,'reload schema';
