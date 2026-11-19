-- Linket Owner Dashboard upgrade
-- Run once in Supabase SQL Editor. Additive migration: does not delete or reset existing player data.

create table if not exists public.linket_owner_events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 100),
  message text not null check (char_length(message) between 1 and 1000),
  starts_at timestamptz,
  ends_at timestamptz,
  reward_tokens integer not null default 0 check (reward_tokens between 0 and 1000000),
  status text not null default 'draft' check (status in ('draft','scheduled','active','ended')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists linket_owner_events_status_idx on public.linket_owner_events(status, starts_at);
alter table public.linket_owner_events enable row level security;
drop policy if exists "Players can view active Linket events" on public.linket_owner_events;
create policy "Players can view active Linket events" on public.linket_owner_events for select to authenticated using (status='active' and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now()));
revoke all on public.linket_owner_events from anon, authenticated;

create table if not exists public.linket_collectible_catalog (
  collectible_id text primary key,
  display_name text not null,
  emoji text not null default '✨',
  rarity text not null check (rarity in ('Common','Rare','Epic','Legendary','Mythical')),
  pack_name text not null default 'All Packs',
  drop_weight numeric(12,4) not null default 1 check (drop_weight>=0),
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.linket_collectible_catalog enable row level security;
drop policy if exists "Players can view enabled collectible catalog" on public.linket_collectible_catalog;
create policy "Players can view enabled collectible catalog" on public.linket_collectible_catalog for select to authenticated using (enabled=true);
revoke all on public.linket_collectible_catalog from anon, authenticated;

insert into public.linket_collectible_catalog(collectible_id,display_name,emoji,rarity,pack_name,drop_weight) values
('Happy Turtle','Happy Turtle','🐢','Common','All Packs',1),
('Tiny Bee','Tiny Bee','🐝','Common','All Packs',1),
('Bouncy Bunny','Bouncy Bunny','🐰','Common','All Packs',1),
('Robot Buddy','Robot Buddy','🤖','Rare','All Packs',1),
('Frost Wolf','Frost Wolf','🐺','Epic','All Packs',1),
('Golden Owl','Golden Owl','🦉','Legendary','All Packs',1),
('Crystal Cat','Crystal Cat','🐱','Legendary','All Packs',1),
('Lumi Fox','Lumi Fox','🦊','Mythical','All Packs',1),
('Galaxy Dragon','Galaxy Dragon','🐉','Mythical','All Packs',1),
('Starwing','Starwing','🦄','Mythical','All Packs',1),
('Seashell Snail','Seashell Snail','🐌','Common','Beach Pack',1),
('Surfer Seal','Surfer Seal','🦭','Common','Beach Pack',1),
('Crab Pal','Crab Pal','🦀','Rare','Beach Pack',1),
('Coral Turtle','Coral Turtle','🐢','Epic','Beach Pack',1),
('Pearl Dolphin','Pearl Dolphin','🐬','Legendary','Beach Pack',1),
('Tidal Phoenix','Tidal Phoenix','🦅','Mythical','Beach Pack',1),
('Moon Moth','Moon Moth','🦋','Common','Space Pack',1),
('Astro Pup','Astro Pup','🐕‍🦺','Common','Space Pack',1),
('Comet Cat','Comet Cat','🐈','Rare','Space Pack',1),
('Nebula Fox','Nebula Fox','🦊','Epic','Space Pack',1),
('Solar Dragon','Solar Dragon','🐲','Legendary','Space Pack',1),
('Void Unicorn','Void Unicorn','🦄','Mythical','Space Pack',1),
('Puppy Pal','Puppy Pal','🐶','Common','Dog Pack',1),
('Corgi Buddy','Corgi Buddy','🐕','Common','Dog Pack',1),
('Dalmatian Dash','Dalmatian Dash','🐾','Rare','Dog Pack',1),
('Shiba Star','Shiba Star','🐕','Epic','Dog Pack',1),
('Golden Retriever','Golden Retriever','🦮','Legendary','Dog Pack',1),
('Cosmic Wolf','Cosmic Wolf','🐺','Mythical','Dog Pack',1)
on conflict (collectible_id) do nothing;

create or replace function public.linket_owner_dashboard_is_owner()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and is_owner=true); $$;

create or replace function public.linket_owner_list_collectibles()
returns table(collectible_id text,display_name text,emoji text,rarity text,pack_name text,drop_weight numeric,enabled boolean)
language plpgsql security definer set search_path=public
as $$ begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 return query select c.collectible_id,c.display_name,c.emoji,c.rarity,c.pack_name,c.drop_weight,c.enabled from public.linket_collectible_catalog c order by c.pack_name,c.rarity,c.display_name;
end; $$;

create or replace function public.linket_owner_save_collectible(p_collectible_id text,p_display_name text,p_emoji text,p_rarity text,p_pack_name text,p_drop_weight numeric,p_enabled boolean)
returns void language plpgsql security definer set search_path=public
as $$ begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 if length(trim(coalesce(p_collectible_id,'')))=0 or length(trim(coalesce(p_display_name,'')))=0 then raise exception 'Collectible ID and name are required.'; end if;
 if p_rarity not in ('Common','Rare','Epic','Legendary','Mythical') then raise exception 'Invalid rarity.'; end if;
 if p_drop_weight<0 or p_drop_weight>1000000 then raise exception 'Drop weight must be between 0 and 1,000,000.'; end if;
 insert into public.linket_collectible_catalog(collectible_id,display_name,emoji,rarity,pack_name,drop_weight,enabled,updated_at)
 values(trim(p_collectible_id),trim(p_display_name),coalesce(nullif(trim(p_emoji),''),'✨'),p_rarity,coalesce(nullif(trim(p_pack_name),''),'All Packs'),p_drop_weight,coalesce(p_enabled,true),now())
 on conflict(collectible_id) do update set display_name=excluded.display_name,emoji=excluded.emoji,rarity=excluded.rarity,pack_name=excluded.pack_name,drop_weight=excluded.drop_weight,enabled=excluded.enabled,updated_at=now();
end; $$;

create or replace function public.linket_owner_save_event(p_event_id uuid,p_title text,p_message text,p_starts_at timestamptz,p_ends_at timestamptz,p_reward_tokens integer,p_status text)
returns uuid language plpgsql security definer set search_path=public
as $$ declare v_id uuid; begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 if length(trim(coalesce(p_title,''))) not between 1 and 100 or length(trim(coalesce(p_message,''))) not between 1 and 1000 then raise exception 'Enter an event title and message.'; end if;
 if p_reward_tokens<0 or p_reward_tokens>1000000 then raise exception 'Reward must be between 0 and 1,000,000 tokens.'; end if;
 if p_status not in ('draft','scheduled','active','ended') then raise exception 'Invalid event status.'; end if;
 if p_starts_at is not null and p_ends_at is not null and p_ends_at<=p_starts_at then raise exception 'Event end must be after its start.'; end if;
 if p_event_id is null then
  insert into public.linket_owner_events(title,message,starts_at,ends_at,reward_tokens,status,created_by) values(trim(p_title),trim(p_message),p_starts_at,p_ends_at,p_reward_tokens,p_status,auth.uid()) returning id into v_id;
 else
  update public.linket_owner_events set title=trim(p_title),message=trim(p_message),starts_at=p_starts_at,ends_at=p_ends_at,reward_tokens=p_reward_tokens,status=p_status,updated_at=now() where id=p_event_id returning id into v_id;
  if v_id is null then raise exception 'Event not found.'; end if;
 end if;
 return v_id;
end; $$;

create or replace function public.linket_owner_list_events()
returns table(id uuid,title text,message text,starts_at timestamptz,ends_at timestamptz,reward_tokens integer,status text,created_at timestamptz)
language plpgsql security definer set search_path=public
as $$ begin
 if not public.linket_owner_dashboard_is_owner() then raise exception 'Owner access required.'; end if;
 return query select e.id,e.title,e.message,e.starts_at,e.ends_at,e.reward_tokens,e.status,e.created_at from public.linket_owner_events e order by e.created_at desc;
end; $$;

revoke all on function public.linket_owner_dashboard_is_owner() from public;
revoke all on function public.linket_owner_list_collectibles() from public;
revoke all on function public.linket_owner_save_collectible(text,text,text,text,text,numeric,boolean) from public;
revoke all on function public.linket_owner_save_event(uuid,text,text,timestamptz,timestamptz,integer,text) from public;
revoke all on function public.linket_owner_list_events() from public;
grant execute on function public.linket_owner_list_collectibles() to authenticated;
grant execute on function public.linket_owner_save_collectible(text,text,text,text,text,numeric,boolean) to authenticated;
grant execute on function public.linket_owner_save_event(uuid,text,text,timestamptz,timestamptz,integer,text) to authenticated;
grant execute on function public.linket_owner_list_events() to authenticated;
