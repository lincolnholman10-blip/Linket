-- Linket: restore the signed-in owner's balance to one quadrillion tokens.
-- Run once in the Supabase SQL Editor.

-- A regular integer cannot hold 1,000,000,000,000,000, so use a wide numeric type.
alter table public.profiles
  alter column tokens type numeric(20,0)
  using coalesce(tokens, 0)::numeric(20,0);

create or replace function public.linket_owner_restore_quadrillion_tokens()
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric(20,0);
begin
  if not exists (
    select 1
    from public.profiles
    where id = auth.uid() and is_owner = true
  ) then
    raise exception 'Owner access required.';
  end if;

  update public.profiles
    set tokens = 1000000000000000
    where id = auth.uid()
    returning tokens into v_balance;

  if not found then
    raise exception 'Owner profile not found.';
  end if;

  return v_balance;
end;
$$;

revoke all on function public.linket_owner_restore_quadrillion_tokens() from public;
grant execute on function public.linket_owner_restore_quadrillion_tokens() to authenticated;
