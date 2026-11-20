-- Linket Live Event Manager save/list support
create table if not exists public.linket_live_events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  message text not null default '',
  starts_at timestamptz,
  ends_at timestamptz,
  reward_tokens integer not null default 0,
  status text not null default 'draft',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint linket_live_events_title_length check (char_length(trim(title)) between 1 and 100),
  constraint linket_live_events_message_length check (char_length(message) <= 1000),
  constraint linket_live_events_reward_check check (reward_tokens between 0 and 1000000),
  constraint linket_live_events_status_check check (status in ('draft','scheduled','active','ended')),
  constraint linket_live_events_dates_check check (starts_at is null or ends_at is null or ends_at > starts_at)
);

alter table public.linket_live_events enable row level security;
revoke all on public.linket_live_events from anon, authenticated;

create or replace function public.linket_owner_save_event(
  p_event_id uuid,
  p_title text,
  p_message text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reward_tokens integer,
  p_status text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then
    raise exception 'Owner access required.';
  end if;
  if nullif(trim(coalesce(p_title,'')), '') is null then
    raise exception 'Enter an event title.';
  end if;
  if char_length(trim(p_title)) > 100 then
    raise exception 'Event title must be 100 characters or fewer.';
  end if;
  if char_length(coalesce(p_message,'')) > 1000 then
    raise exception 'Event details must be 1,000 characters or fewer.';
  end if;
  if p_reward_tokens is null or p_reward_tokens < 0 or p_reward_tokens > 1000000 then
    raise exception 'Token reward must be between 0 and 1,000,000.';
  end if;
  if p_status not in ('draft','scheduled','active','ended') then
    raise exception 'Choose a valid event status.';
  end if;
  if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'The end time must be later than the start time.';
  end if;

  if p_event_id is null then
    insert into public.linket_live_events
      (title,message,starts_at,ends_at,reward_tokens,status,created_by)
    values
      (trim(p_title),coalesce(p_message,''),p_starts_at,p_ends_at,p_reward_tokens,p_status,auth.uid())
    returning id into v_id;
  else
    update public.linket_live_events
       set title=trim(p_title), message=coalesce(p_message,''),
           starts_at=p_starts_at, ends_at=p_ends_at,
           reward_tokens=p_reward_tokens, status=p_status, updated_at=now()
     where id=p_event_id;
    if not found then raise exception 'Event not found.'; end if;
    v_id := p_event_id;
  end if;
  return v_id;
end;
$$;

drop function if exists public.linket_owner_list_events();

create or replace function public.linket_owner_list_events()
returns table (
  id uuid,
  title text,
  message text,
  starts_at timestamptz,
  ends_at timestamptz,
  reward_tokens integer,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then
    raise exception 'Owner access required.';
  end if;
  return query
    select e.id,e.title,e.message,e.starts_at,e.ends_at,e.reward_tokens,e.status,e.created_at,e.updated_at
    from public.linket_live_events e
    order by e.created_at desc;
end;
$$;

revoke all on function public.linket_owner_save_event(uuid,text,text,timestamptz,timestamptz,integer,text) from public, anon;
revoke all on function public.linket_owner_list_events() from public, anon;
grant execute on function public.linket_owner_save_event(uuid,text,text,timestamptz,timestamptz,integer,text) to authenticated;
grant execute on function public.linket_owner_list_events() to authenticated;
notify pgrst, 'reload schema';
