-- Private gift notifications for Linket players.
create table if not exists public.linket_player_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  message text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists linket_player_notifications_unread_idx
  on public.linket_player_notifications(user_id, created_at desc)
  where read_at is null;
alter table public.linket_player_notifications enable row level security;
revoke all on public.linket_player_notifications from anon, authenticated;

create or replace function public.linket_owner_send_gift_notification(
  p_user_id uuid,
  p_title text,
  p_message text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_owner = true
  ) then
    raise exception 'Owner access only.';
  end if;
  if p_user_id is null or not exists (
    select 1 from public.profiles p where p.id = p_user_id
  ) then
    raise exception 'Player not found.';
  end if;
  if length(trim(coalesce(p_title, ''))) not between 1 and 100
     or length(trim(coalesce(p_message, ''))) not between 1 and 500 then
    raise exception 'A valid notification title and message are required.';
  end if;

  insert into public.linket_player_notifications(user_id, title, message)
  values (p_user_id, trim(p_title), trim(p_message))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.linket_player_take_gift_notifications()
returns table(notification_id uuid, title text, message text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in required.';
  end if;

  return query
  with pending as (
    select n.id
    from public.linket_player_notifications n
    where n.user_id = auth.uid() and n.read_at is null
    order by n.created_at asc
    for update
  ),
  marked as (
    update public.linket_player_notifications n
    set read_at = now()
    from pending p
    where n.id = p.id
    returning n.id, n.title, n.message, n.created_at
  )
  select m.id, m.title, m.message, m.created_at
  from marked m
  order by m.created_at asc;
end;
$$;

revoke all on function public.linket_owner_send_gift_notification(uuid,text,text) from public, anon;
revoke all on function public.linket_player_take_gift_notifications() from public, anon;
grant execute on function public.linket_owner_send_gift_notification(uuid,text,text) to authenticated;
grant execute on function public.linket_player_take_gift_notifications() to authenticated;
