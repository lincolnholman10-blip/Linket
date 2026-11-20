-- Linket: require a reason for owner token deductions and notify affected players.
-- Run this migration in the Supabase SQL Editor after deploying the matching index.html.

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

-- Replace the previous three-argument RPC so every adjustment passes the reason slot.
drop function if exists public.linket_owner_adjust_tokens(uuid, integer, integer);

create function public.linket_owner_adjust_tokens(
  p_user_id uuid,
  p_amount integer,
  p_direction integer,
  p_reason text
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current numeric;
  v_new_balance numeric;
  v_changed numeric;
  v_reason text := trim(coalesce(p_reason, ''));
  v_username text;
begin
  if auth.uid() is null or not public.linket_owner_dashboard_is_owner() then
    raise exception 'Owner access required.';
  end if;

  if p_user_id is null then
    raise exception 'Choose a player.';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000000 then
    raise exception 'Token amount must be between 1 and 1,000,000,000.';
  end if;
  if p_direction is null or p_direction not in (-1, 1) then
    raise exception 'Invalid token adjustment direction.';
  end if;
  if p_direction = -1 and length(v_reason) = 0 then
    raise exception 'A reason is required when removing tokens.';
  end if;
  if length(v_reason) > 300 then
    raise exception 'The reason must be 300 characters or fewer.';
  end if;

  select coalesce(p.tokens, 0)::numeric, p.username
    into v_current, v_username
    from public.profiles p
    where p.id = p_user_id
    for update;

  if not found then
    raise exception 'Player account not found.';
  end if;

  v_new_balance := case
    when p_direction = 1 then v_current + p_amount
    else greatest(0, v_current - p_amount)
  end;
  v_changed := abs(v_new_balance - v_current);

  if v_changed = 0 then
    raise exception 'No tokens were changed. This player has no tokens to remove.';
  end if;

  update public.profiles
    set tokens = v_new_balance
    where id = p_user_id;

  -- Queue a private, one-time popup for the next login.
  if p_user_id <> auth.uid() then
    if p_direction = -1 then
      insert into public.linket_player_notifications(user_id, title, message)
      values (
        p_user_id,
        '⚠️ Token update from Linket',
        'The Linket owner removed ' || to_char(v_changed, 'FM999,999,999,999,999,990') ||
        ' tokens from your balance. Reason: ' || v_reason
      );
    else
      insert into public.linket_player_notifications(user_id, title, message)
      values (
        p_user_id,
        '🎁 You received tokens!',
        'The Linket owner gave you ' || to_char(v_changed, 'FM999,999,999,999,999,990') || ' tokens!'
      );
    end if;
  end if;

  return v_new_balance;
end;
$$;

revoke all on function public.linket_owner_adjust_tokens(uuid, integer, integer, text) from public, anon;
grant execute on function public.linket_owner_adjust_tokens(uuid, integer, integer, text) to authenticated;

notify pgrst, 'reload schema';
