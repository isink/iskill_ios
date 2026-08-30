-- Iskill database schema
-- Run this on a fresh Supabase project: psql < schema.sql
-- or paste into the Supabase SQL editor.

create extension if not exists "uuid-ossp";
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- categories
-- ---------------------------------------------------------------------------
create table if not exists public.categories (
  id         uuid primary key default uuid_generate_v4(),
  slug       text not null unique,
  name       text not null,
  icon       text not null default 'sparkles',
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- skills
-- ---------------------------------------------------------------------------
create table if not exists public.skills (
  id               uuid primary key default uuid_generate_v4(),
  slug             text not null unique,
  name             text not null,
  description      text not null default '',
  category         text not null references public.categories(slug) on update cascade,
  tags             text[] not null default '{}',
  author           text not null default '',
  github_url       text not null default '',
  skill_md_content text,
  github_stars     integer,
  rank             integer not null default 0,
  score            integer not null default 0,
  featured         boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists skills_category_idx  on public.skills (category);
create index if not exists skills_rank_idx      on public.skills (rank desc);
create index if not exists skills_featured_idx  on public.skills (featured) where featured = true;
create index if not exists skills_name_trgm_idx on public.skills using gin (name gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- favorites (optional, per-user)
-- ---------------------------------------------------------------------------
create table if not exists public.favorites (
  user_id    uuid not null references auth.users(id) on delete cascade,
  skill_id   uuid not null references public.skills(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, skill_id)
);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists skills_set_updated_at on public.skills;
create trigger skills_set_updated_at
before update on public.skills
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- row level security: anon can read skills + categories, nothing else
-- ---------------------------------------------------------------------------
alter table public.skills     enable row level security;
alter table public.categories enable row level security;
alter table public.favorites  enable row level security;

drop policy if exists "skills read" on public.skills;
create policy "skills read" on public.skills
  for select using (true);

drop policy if exists "categories read" on public.categories;
create policy "categories read" on public.categories
  for select using (true);

drop policy if exists "favorites owner" on public.favorites;
create policy "favorites owner" on public.favorites
  for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on table public.favorites from public, anon;
grant select, insert, update, delete on table public.favorites to authenticated;

-- ---------------------------------------------------------------------------
-- Chinese enrichment columns (added for CN market)
-- ---------------------------------------------------------------------------
alter table public.skills
  add column if not exists description_zh text,
  add column if not exists use_cases      text[] not null default '{}';

-- ---------------------------------------------------------------------------
-- authenticated account deletion
-- ---------------------------------------------------------------------------
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
