-- Linket: restore the signed-in owner's balance to one quadrillion tokens.
-- Run this entire migration once in the Supabase SQL Editor.
-- Existing profiles policies and triggers are captured and recreated unchanged around the type change.

do $migration$
declare
  v_policy_defs jsonb := '[]'::jsonb;
  v_trigger_defs jsonb := '[]'::jsonb;
  v_policy record;
  v_trigger record;
  v_saved jsonb;
  v_sql text;
begin
  -- Save every policy on profiles, then drop them temporarily so PostgreSQL
  -- can change the tokens column type without losing any security rules.
  for v_policy in
    select
      p.polname,
      case p.polcmd
        when '*' then 'ALL'
        when 'r' then 'SELECT'
        when 'a' then 'INSERT'
        when 'w' then 'UPDATE'
        when 'd' then 'DELETE'
      end as command_name,
      case when p.polpermissive then 'PERMISSIVE' else 'RESTRICTIVE' end as policy_mode,
      coalesce((
        select string_agg(
          case when role_id = 0 then 'public'
               else quote_ident(r.rolname)
          end, ', '
        )
        from unnest(p.polroles) as role_id
        left join pg_roles r on r.oid = role_id
      ), 'public') as roles_sql,
      pg_get_expr(p.polqual, p.polrelid) as using_expr,
      pg_get_expr(p.polwithcheck, p.polrelid) as check_expr
    from pg_policy p
    where p.polrelid = 'public.profiles'::regclass
  loop
    v_policy_defs := v_policy_defs || jsonb_build_array(jsonb_build_object(
      'name', v_policy.polname,
      'command', v_policy.command_name,
      'mode', v_policy.policy_mode,
      'roles', v_policy.roles_sql,
      'using_expr', v_policy.using_expr,
      'check_expr', v_policy.check_expr
    ));
    execute format('drop policy %I on public.profiles', v_policy.polname);
  end loop;

  -- Triggers such as the token activity logger can depend directly on the
  -- tokens column definition. Save their exact CREATE statements and drop
  -- them temporarily; their trigger functions remain in place.
  for v_trigger in
    select t.tgname, pg_get_triggerdef(t.oid, true) as trigger_sql
    from pg_trigger t
    where t.tgrelid = 'public.profiles'::regclass
      and not t.tgisinternal
  loop
    v_trigger_defs := v_trigger_defs || jsonb_build_array(jsonb_build_object(
      'name', v_trigger.tgname,
      'definition', v_trigger.trigger_sql
    ));
    execute format('drop trigger %I on public.profiles', v_trigger.tgname);
  end loop;

  alter table public.profiles
    alter column tokens type numeric(20,0)
    using coalesce(tokens, 0)::numeric(20,0);

  -- Restore triggers exactly as they were before the type change.
  for v_saved in select value from jsonb_array_elements(v_trigger_defs)
  loop
    execute v_saved->>'definition';
  end loop;

  -- Recreate every profiles policy with its original command, roles and expressions.
  for v_saved in select value from jsonb_array_elements(v_policy_defs)
  loop
    v_sql := format(
      'create policy %I on public.profiles as %s for %s to %s',
      v_saved->>'name',
      v_saved->>'mode',
      v_saved->>'command',
      v_saved->>'roles'
    );
    if v_saved->>'using_expr' is not null then
      v_sql := v_sql || format(' using (%s)', v_saved->>'using_expr');
    end if;
    if v_saved->>'check_expr' is not null then
      v_sql := v_sql || format(' with check (%s)', v_saved->>'check_expr');
    end if;
    execute v_sql;
  end loop;
end
$migration$;

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
