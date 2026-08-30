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
    from pg_constraint
    where conrelid = 'public.favorites'::regclass
      and contype = 'f'
      and confrelid = 'auth.users'::regclass
  ) then
    alter table public.favorites
      add constraint favorites_user_id_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
end;
$$;

alter table public.favorites enable row level security;

revoke all on table public.favorites from public, anon;
grant select, insert, update, delete on table public.favorites to authenticated;

drop policy if exists "favorites owner" on public.favorites;
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

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

commit;
