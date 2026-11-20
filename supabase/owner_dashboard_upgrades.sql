-- Linket Owner Dashboard upgrades: Secret Creator
-- Live Game Statistics and Player Activity Monitor use the existing owner player
-- list and recent-activity RPCs; this migration adds private saved secret drafts.

create table if not exists public.linket_owner_secret_creations (
  id uuid primary key default gen_random_uuid(),
  collectible_id text not null unique,
  emoji text not null,
  rarity text not null check (rarity in ('Mythical','Chroma')),
  description text not null,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.linket_owner_secret_creations enable row level security;
revoke all on public.linket_owner_secret_creations from public, anon, authenticated;

create or replace function public.linket_owner_create_secret(
  p_collectible_id text,
  p_emoji text,
  p_rarity text,
  p_description text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_name text := btrim(coalesce(p_collectible_id,''));
  v_emoji text := btrim(coalesce(p_emoji,''));
  v_description text := btrim(coalesce(p_description,''));
begin
  if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then
    raise exception 'Owner access only.';
  end if;
  if v_name='' or length(v_name)>80 then raise exception 'Secret name must be 1 to 80 characters.'; end if;
  if v_emoji='' or length(v_emoji)>12 then raise exception 'Enter a valid emoji.'; end if;
  if v_description='' or length(v_description)>300 then raise exception 'Description must be 1 to 300 characters.'; end if;
  if p_rarity not in ('Mythical','Chroma') then raise exception 'Choose Mythical or Chroma rarity.'; end if;
  insert into public.linket_owner_secret_creations(collectible_id,emoji,rarity,description,created_by)
  values(v_name,v_emoji,p_rarity,v_description,auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.linket_owner_list_secret_creations()
returns table(id uuid,collectible_id text,emoji text,rarity text,description text,created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then
    raise exception 'Owner access only.';
  end if;
  return query
  select s.id,s.collectible_id,s.emoji,s.rarity,s.description,s.created_at
  from public.linket_owner_secret_creations s
  order by s.created_at desc;
end;
$$;

revoke all on function public.linket_owner_create_secret(text,text,text,text) from public, anon;
revoke all on function public.linket_owner_list_secret_creations() from public, anon;
grant execute on function public.linket_owner_create_secret(text,text,text,text) to authenticated;
grant execute on function public.linket_owner_list_secret_creations() to authenticated;

notify pgrst, 'reload schema';
