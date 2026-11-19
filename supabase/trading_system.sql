-- Linket Trading System
-- Run this entire file once in Supabase SQL Editor.
create table if not exists public.linket_trades (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  sender_confirmed boolean not null default true,
  recipient_confirmed boolean not null default false,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint linket_trade_not_self check (sender_id <> recipient_id)
);
create table if not exists public.linket_trade_items (
  id bigint generated always as identity primary key,
  trade_id uuid not null references public.linket_trades(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  collectible_id text not null,
  quantity integer not null check (quantity > 0),
  unique(trade_id, owner_id, collectible_id)
);
create index if not exists linket_trades_sender_idx on public.linket_trades(sender_id, created_at desc);
create index if not exists linket_trades_recipient_idx on public.linket_trades(recipient_id, created_at desc);
alter table public.linket_trades enable row level security;
alter table public.linket_trade_items enable row level security;
drop policy if exists "Users can view their trades" on public.linket_trades;
create policy "Users can view their trades" on public.linket_trades for select to authenticated using (auth.uid() = sender_id or auth.uid() = recipient_id);
drop policy if exists "Users can view trade items for their trades" on public.linket_trade_items;
create policy "Users can view trade items for their trades" on public.linket_trade_items for select to authenticated using (exists(select 1 from public.linket_trades t where t.id=trade_id and (t.sender_id=auth.uid() or t.recipient_id=auth.uid())));
revoke all on public.linket_trades from anon, authenticated;
revoke all on public.linket_trade_items from anon, authenticated;
grant select on public.linket_trades, public.linket_trade_items to authenticated;

create or replace function public.linket_trade_search_players(p_search text)
returns table(player_id uuid, username text)
language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null then raise exception 'Please sign in.'; end if;
 if length(trim(coalesce(p_search,''))) < 2 then raise exception 'Enter at least 2 characters.'; end if;
 return query
 select p.id, p.username::text from public.profiles p
 where p.id <> auth.uid() and coalesce(p.is_banned,false)=false
 and p.username ilike '%' || left(trim(p_search),24) || '%'
 order by p.username limit 15;
end; $$;

create or replace function public.linket_trade_create(p_recipient_id uuid, p_offer jsonb, p_request jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_trade uuid; v_item record; v_total int:=0;
begin
 if auth.uid() is null then raise exception 'Please sign in.'; end if;
 if p_recipient_id is null or p_recipient_id=auth.uid() then raise exception 'Choose another player.'; end if;
 if not exists(select 1 from public.profiles where id=p_recipient_id and coalesce(is_banned,false)=false) then raise exception 'Player not found.'; end if;
 if jsonb_typeof(coalesce(p_offer,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_request,'[]'::jsonb))<>'array' then raise exception 'Invalid trade items.'; end if;
 if jsonb_array_length(coalesce(p_offer,'[]'::jsonb))>10 or jsonb_array_length(coalesce(p_request,'[]'::jsonb))>10 then raise exception 'A trade can include at most 10 collectible types per side.'; end if;
 if jsonb_array_length(coalesce(p_offer,'[]'::jsonb))=0 and jsonb_array_length(coalesce(p_request,'[]'::jsonb))=0 then raise exception 'Add at least one collectible to the trade.'; end if;
 for v_item in select value from jsonb_array_elements(coalesce(p_offer,'[]'::jsonb)) loop
  if coalesce((v_item.value->>'quantity')::int,0)<1 or (v_item.value->>'quantity')::int>100 then raise exception 'Trade quantities must be between 1 and 100.'; end if;
  if not exists(select 1 from public.owned_collectibles o where o.user_id=auth.uid() and o.collectible_id=v_item.value->>'collectible_id' and o.quantity >= (v_item.value->>'quantity')::int) then raise exception 'You do not own enough of %.',v_item.value->>'collectible_id'; end if;
 end loop;
 insert into public.linket_trades(sender_id,recipient_id) values(auth.uid(),p_recipient_id) returning id into v_trade;
 for v_item in select value from jsonb_array_elements(coalesce(p_offer,'[]'::jsonb)) loop
  insert into public.linket_trade_items(trade_id,owner_id,collectible_id,quantity) values(v_trade,auth.uid(),v_item.value->>'collectible_id',(v_item.value->>'quantity')::int);
 end loop;
 for v_item in select value from jsonb_array_elements(coalesce(p_request,'[]'::jsonb)) loop
  if coalesce((v_item.value->>'quantity')::int,0)<1 or (v_item.value->>'quantity')::int>100 then raise exception 'Trade quantities must be between 1 and 100.'; end if;
  insert into public.linket_trade_items(trade_id,owner_id,collectible_id,quantity) values(v_trade,p_recipient_id,v_item.value->>'collectible_id',(v_item.value->>'quantity')::int);
 end loop;
 return v_trade;
end; $$;

create or replace function public.linket_trade_respond(p_trade_id uuid, p_accept boolean)
returns text language plpgsql security definer set search_path=public
as $$
declare t public.linket_trades%rowtype; it record; v_have int;
begin
 if auth.uid() is null then raise exception 'Please sign in.'; end if;
 select * into t from public.linket_trades where id=p_trade_id for update;
 if not found then raise exception 'Trade not found.'; end if;
 if t.recipient_id<>auth.uid() then raise exception 'Only the recipient can respond to this trade.'; end if;
 if t.status<>'pending' then raise exception 'This trade is no longer pending.'; end if;
 if not p_accept then update public.linket_trades set status='declined' where id=p_trade_id; return 'declined'; end if;
 -- Lock all affected inventory rows and verify both players still own the offered items.
 for it in select * from public.linket_trade_items where trade_id=p_trade_id order by owner_id,collectible_id loop
  select quantity into v_have from public.owned_collectibles where user_id=it.owner_id and collectible_id=it.collectible_id for update;
  if coalesce(v_have,0)<it.quantity then raise exception 'A player no longer owns enough %; the trade was not completed.',it.collectible_id; end if;
 end loop;
 -- Remove all outgoing copies first, then add incoming copies. All changes are atomic.
 for it in select * from public.linket_trade_items where trade_id=p_trade_id order by owner_id,collectible_id loop
  update public.owned_collectibles set quantity=quantity-it.quantity where user_id=it.owner_id and collectible_id=it.collectible_id;
  delete from public.owned_collectibles where user_id=it.owner_id and collectible_id=it.collectible_id and quantity<=0;
 end loop;
 for it in select * from public.linket_trade_items where trade_id=p_trade_id loop
  insert into public.owned_collectibles(user_id,collectible_id,quantity)
  values(case when it.owner_id=t.sender_id then t.recipient_id else t.sender_id end,it.collectible_id,it.quantity)
  on conflict(user_id,collectible_id) do update set quantity=public.owned_collectibles.quantity+excluded.quantity;
 end loop;
 update public.linket_trades set status='accepted',recipient_confirmed=true,completed_at=now() where id=p_trade_id;
 return 'accepted';
end; $$;

create or replace function public.linket_trade_cancel(p_trade_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
begin
 update public.linket_trades set status='cancelled'
 where id=p_trade_id and sender_id=auth.uid() and status='pending';
 if not found then raise exception 'This trade cannot be cancelled.'; end if;
end; $$;

create or replace function public.linket_trade_list()
returns table(id uuid,sender_id uuid,recipient_id uuid,sender_name text,recipient_name text,status text,created_at timestamptz,completed_at timestamptz,items jsonb)
language sql security definer set search_path=public
as $$
 select t.id,t.sender_id,t.recipient_id,ps.username::text,pr.username::text,t.status,t.created_at,t.completed_at,
 coalesce((select jsonb_agg(jsonb_build_object('owner_id',i.owner_id,'collectible_id',i.collectible_id,'quantity',i.quantity)) from public.linket_trade_items i where i.trade_id=t.id),'[]'::jsonb)
 from public.linket_trades t
 join public.profiles ps on ps.id=t.sender_id
 join public.profiles pr on pr.id=t.recipient_id
 where auth.uid()=t.sender_id or auth.uid()=t.recipient_id
 order by t.created_at desc limit 100;
$$;
revoke all on function public.linket_trade_search_players(text) from public;
revoke all on function public.linket_trade_create(uuid,jsonb,jsonb) from public;
revoke all on function public.linket_trade_respond(uuid,boolean) from public;
revoke all on function public.linket_trade_cancel(uuid) from public;
revoke all on function public.linket_trade_list() from public;
grant execute on function public.linket_trade_search_players(text) to authenticated;
grant execute on function public.linket_trade_create(uuid,jsonb,jsonb) to authenticated;
grant execute on function public.linket_trade_respond(uuid,boolean) to authenticated;
grant execute on function public.linket_trade_cancel(uuid) to authenticated;
grant execute on function public.linket_trade_list() to authenticated;
