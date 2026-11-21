-- Let signed-in players change their own Linket username safely.
create or replace function public.linket_change_username(p_username text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_username text := btrim(coalesce(p_username, ''));
begin
  if v_user_id is null then
    raise exception 'Sign in to change your username.';
  end if;

  if length(v_username) < 3 or length(v_username) > 24 then
    raise exception 'Username must be between 3 and 24 characters.';
  end if;

  if v_username !~ '^[A-Za-z0-9_ ]+$' then
    raise exception 'Use only letters, numbers, spaces, and underscores.';
  end if;

  -- Serialize username changes so two players cannot claim the same name at once.
  perform pg_advisory_xact_lock(hashtext('linket_username_change'));

  if exists (
    select 1
    from public.profiles p
    where lower(p.username) = lower(v_username)
      and p.id <> v_user_id
  ) then
    raise exception 'That username is already taken. Choose another one.';
  end if;

  update public.profiles
  set username = v_username
  where id = v_user_id;

  if not found then
    raise exception 'Player profile not found.';
  end if;

  return v_username;
end;
$$;

revoke all on function public.linket_change_username(text) from public, anon;
grant execute on function public.linket_change_username(text) to authenticated;

notify pgrst, 'reload schema';
