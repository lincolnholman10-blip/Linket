-- Linket owner token adjustment
-- Uses the same owner-check helper as the working Owner Dashboard functions.
-- Run this updated file in the Supabase SQL Editor.

create or replace function public.linket_owner_adjust_tokens(
  p_user_id uuid,
  p_amount integer,
  p_direction integer
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current numeric;
  v_new_balance numeric;
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

  select coalesce(tokens, 0)::numeric
    into v_current
    from public.profiles
    where id = p_user_id
    for update;

  if not found then
    raise exception 'Player account not found.';
  end if;

  v_new_balance := greatest(0, v_current + (p_amount * p_direction));

  update public.profiles
    set tokens = v_new_balance
    where id = p_user_id;

  return v_new_balance;
end;
$$;

revoke all on function public.linket_owner_adjust_tokens(uuid, integer, integer) from public;
revoke all on function public.linket_owner_adjust_tokens(uuid, integer, integer) from anon;
grant execute on function public.linket_owner_adjust_tokens(uuid, integer, integer) to authenticated;
