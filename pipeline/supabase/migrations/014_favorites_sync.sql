begin;

create table if not exists public.favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  skill_id uuid not null references public.skills(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, skill_id)
);

do $$
declare
  primary_key_columns text[];
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'favorites'
      and column_name = 'user_id'
  ) or not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'favorites'
      and column_name = 'skill_id'
  ) then
    raise exception 'public.favorites must contain user_id and skill_id columns';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'favorites'
      and column_name in ('user_id', 'skill_id')
      and data_type <> 'uuid'
  ) then
    raise exception 'public.favorites user_id and skill_id must both use uuid';
  end if;

  select array_agg(attribute.attname order by key_column.ordinality)
    into primary_key_columns
  from pg_constraint as constraint_definition
  cross join unnest(constraint_definition.conkey)
    with ordinality as key_column(attribute_number, ordinality)
  join pg_attribute as attribute
    on attribute.attrelid = constraint_definition.conrelid
   and attribute.attnum = key_column.attribute_number
  where constraint_definition.conrelid = 'public.favorites'::regclass
    and constraint_definition.contype = 'p';

  if primary_key_columns is distinct from array['user_id', 'skill_id']::text[] then
    raise exception 'public.favorites must use primary key (user_id, skill_id)';
  end if;

  if exists (
    select 1
    from public.favorites as favorite
    left join auth.users as account on account.id = favorite.user_id
    where account.id is null
  ) then
    raise exception 'public.favorites contains user_id values missing from auth.users';
  end if;

  if not exists (
    select 1
    from pg_constraint as constraint_definition
    where constraint_definition.conrelid = 'public.favorites'::regclass
      and constraint_definition.contype = 'f'
      and constraint_definition.confrelid = 'auth.users'::regclass
      and constraint_definition.confupdtype = 'a'
      and constraint_definition.confdeltype = 'c'
      and constraint_definition.confmatchtype = 's'
      and not constraint_definition.condeferrable
      and constraint_definition.convalidated
      and constraint_definition.conkey = array[(
        select attnum from pg_attribute
        where attrelid = 'public.favorites'::regclass and attname = 'user_id'
      )]::smallint[]
      and constraint_definition.confkey = array[(
        select attnum from pg_attribute
        where attrelid = 'auth.users'::regclass and attname = 'id'
      )]::smallint[]
  ) then
    alter table public.favorites
      add constraint favorites_user_id_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;

  if exists (
    select 1
    from public.favorites as favorite
    left join public.skills as skill on skill.id = favorite.skill_id
    where skill.id is null
  ) then
    raise exception 'public.favorites contains skill_id values missing from public.skills';
  end if;

  if not exists (
    select 1
    from pg_constraint as constraint_definition
    where constraint_definition.conrelid = 'public.favorites'::regclass
      and constraint_definition.contype = 'f'
      and constraint_definition.confrelid = 'public.skills'::regclass
      and constraint_definition.confupdtype = 'a'
      and constraint_definition.confdeltype = 'c'
      and constraint_definition.confmatchtype = 's'
      and not constraint_definition.condeferrable
      and constraint_definition.convalidated
      and constraint_definition.conkey = array[(
        select attnum from pg_attribute
        where attrelid = 'public.favorites'::regclass and attname = 'skill_id'
      )]::smallint[]
      and constraint_definition.confkey = array[(
        select attnum from pg_attribute
        where attrelid = 'public.skills'::regclass and attname = 'id'
      )]::smallint[]
  ) then
    alter table public.favorites
      add constraint favorites_skill_id_fkey
      foreign key (skill_id) references public.skills(id) on delete cascade;
  end if;

  if (
    select count(*)
    from pg_constraint
    where conrelid = 'public.favorites'::regclass
      and contype = 'f'
  ) <> 2 then
    raise exception 'public.favorites must have exactly two foreign keys';
  end if;
end;
$$;

alter table public.favorites enable row level security;

revoke all on table public.favorites from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.favorites to authenticated;
grant select, insert, update, delete on table public.favorites to service_role;

do $$
declare
  existing_policy record;
begin
  for existing_policy in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'favorites'
  loop
    execute format(
      'drop policy %I on public.favorites',
      existing_policy.policyname
    );
  end loop;
end;
$$;

create policy "favorites owner" on public.favorites
  for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  delete from public.favorites where user_id = uid;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account()
  from public, anon, authenticated, service_role;
grant execute on function public.delete_my_account() to authenticated;

commit;
