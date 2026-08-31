-- Controlled representation of the database immediately after migration 013.
-- This is a test fixture, not a production migration. It intentionally keeps
-- the old client-write policies, notification triggers, nullable install count,
-- and favorites table without an auth.users foreign key so 014-016 must perform
-- the real upgrade work.

begin;

create extension if not exists "uuid-ossp";

create table public.categories (
  id uuid primary key default uuid_generate_v4(),
  slug text not null unique,
  name text not null,
  icon text not null default 'sparkles',
  created_at timestamptz not null default now()
);

create table public.skills (
  id uuid primary key default uuid_generate_v4(),
  slug text not null unique,
  name text not null,
  description text not null default '',
  description_zh text,
  category text not null references public.categories(slug) on update cascade,
  tags text[] not null default '{}',
  use_cases text[] not null default '{}',
  use_cases_en text[] not null default '{}',
  author text not null default '',
  github_url text not null default '',
  skill_md_content text,
  github_stars integer,
  install_count integer,
  rank integer not null default 0,
  score integer not null default 0,
  featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.favorites (
  user_id uuid not null,
  skill_id uuid not null references public.skills(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, skill_id)
);

create table public.submissions (
  id uuid primary key default uuid_generate_v4(),
  github_url text not null,
  submitter_email text,
  note text,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  reviewer_note text,
  submitter_user_id uuid references auth.users(id) on delete set null,
  health jsonb,
  agent_decision text check (agent_decision in ('approve', 'reject')),
  agent_reason text,
  agent_reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create table public.skill_reports (
  id uuid primary key default uuid_generate_v4(),
  skill_id text not null,
  skill_slug text,
  skill_name text,
  reason text not null,
  note text,
  reporter_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index submissions_status_idx
  on public.submissions (status, created_at desc);
create index submissions_user_idx
  on public.submissions (submitter_user_id, created_at desc);
create index submissions_pending_no_agent_idx
  on public.submissions (created_at)
  where status = 'pending' and agent_decision is null;
create index skill_reports_created_idx
  on public.skill_reports (created_at desc);
create index skill_reports_skill_idx
  on public.skill_reports (skill_id);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger skills_set_updated_at
before update on public.skills
for each row execute function public.set_updated_at();

alter table public.skills enable row level security;
alter table public.categories enable row level security;
alter table public.favorites enable row level security;
alter table public.submissions enable row level security;
alter table public.skill_reports enable row level security;

create policy "skills read" on public.skills for select using (true);
create policy "categories read" on public.categories for select using (true);
create policy "favorites owner" on public.favorites
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "submissions insert" on public.submissions
  for insert with check (
    submitter_user_id is null or submitter_user_id = auth.uid()
  );
create policy "submissions select own" on public.submissions
  for select using (
    submitter_user_id is not null and submitter_user_id = auth.uid()
  );
create policy "skill_reports insert" on public.skill_reports
  for insert with check (
    reporter_user_id is null or reporter_user_id = auth.uid()
  );

grant select on table public.skills, public.categories to anon, authenticated;
grant all on table public.skills, public.categories to service_role;
grant select, insert, update, delete on table public.favorites to authenticated;
grant all on table public.favorites to service_role;
grant insert on table public.submissions, public.skill_reports to anon, authenticated;
grant all on table public.submissions, public.skill_reports to service_role;

create or replace function public.get_new_counts_by_category(since timestamptz)
returns table(category text, count bigint)
language sql
stable
as $$
  select category, count(*) as count
  from skills
  where created_at > since
  group by category;
$$;

create or replace function public.get_repo_groups(
  p_category text default null,
  p_offset integer default 0,
  p_limit integer default 50
)
returns table(
  repo text,
  author text,
  stars integer,
  skill_count bigint,
  rep_skill_id uuid
)
language sql
stable
as $$
  with base as (
    select
      regexp_replace(github_url, '^https?://github\.com/([^/]+/[^/]+).*$', '\1') as g_repo,
      author,
      github_stars,
      id,
      featured,
      rank,
      install_count
    from skills
    where (p_category is null or category = p_category)
  ), ranked as (
    select
      g_repo,
      author,
      github_stars,
      id,
      row_number() over (
        partition by g_repo
        order by featured desc, rank desc, install_count desc nulls last, id
      ) as rn,
      count(*) over (partition by g_repo) as cnt
    from base
  )
  select g_repo, author, github_stars, cnt, id
  from ranked
  where rn = 1
  order by github_stars desc nulls last, g_repo
  offset p_offset limit p_limit;
$$;

create or replace function public.increment_install_count(skill_id uuid)
returns void
language sql
as $$
  update public.skills
  set install_count = coalesce(install_count, 0) + 1
  where id = skill_id;
$$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  delete from auth.users where id = uid;
end;
$$;

create or replace function public.notify_new_submission()
returns trigger
language plpgsql
security definer
as $$
begin
  return new;
end;
$$;

create trigger submissions_notify_after_insert
after insert on public.submissions
for each row execute function public.notify_new_submission();

create or replace function public.notify_new_report()
returns trigger
language plpgsql
security definer
as $$
begin
  return new;
end;
$$;

create trigger skill_reports_notify_after_insert
after insert on public.skill_reports
for each row execute function public.notify_new_report();

insert into public.categories (id, slug, name)
values (
  '00000000-0000-4000-8000-000000000201',
  'pre-014-category',
  'Pre-014 Category'
);

insert into public.skills (
  id, slug, name, category, author, github_url, install_count, use_cases_en,
  created_at, updated_at
) values
  (
    '00000000-0000-4000-8000-000000000202',
    'pre-014-skill',
    'Pre-014 Skill',
    'pre-014-category',
    'fixture-owner',
    'https://github.com/fixture-owner/fixture-repo',
    null,
    '{}',
    '2026-01-01 00:00:00+00',
    '2026-01-02 00:00:00+00'
  ),
  (
    '00000000-0000-4000-8000-000000000203',
    'pre-014-ranked-skill',
    'Pre-014 Ranked Skill',
    'pre-014-category',
    'fixture-owner',
    'https://github.com/fixture-owner/fixture-repo',
    7,
    '{}',
    '2026-01-01 00:00:00+00',
    '2026-01-03 00:00:00+00'
  );

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
) values
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-4000-8000-000000000211',
    'authenticated',
    'authenticated',
    'favorite-owner@example.invalid',
    '',
    now(),
    '{}',
    '{}',
    now(),
    now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-4000-8000-000000000212',
    'authenticated',
    'authenticated',
    'history-owner@example.invalid',
    '',
    now(),
    '{}',
    '{}',
    now(),
    now()
  );

insert into public.favorites (user_id, skill_id)
values (
  '00000000-0000-4000-8000-000000000211',
  '00000000-0000-4000-8000-000000000202'
);

insert into public.submissions (
  id, github_url, submitter_user_id, note
) values (
  '00000000-0000-4000-8000-000000000221',
  'https://github.com/fixture-owner/fixture-repo',
  '00000000-0000-4000-8000-000000000212',
  'pre-014 submission'
);

insert into public.skill_reports (
  id, skill_id, skill_slug, skill_name, reason, note, reporter_user_id
) values (
  '00000000-0000-4000-8000-000000000222',
  '00000000-0000-4000-8000-000000000202',
  'pre-014-skill',
  'Pre-014 Skill',
  'spam',
  'pre-014 report',
  '00000000-0000-4000-8000-000000000212'
);

do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conrelid = 'public.favorites'::regclass
      and contype = 'f'
      and confrelid = 'auth.users'::regclass
  ) then
    raise exception 'pre-014 fixture unexpectedly has the favorites auth foreign key';
  end if;

  if to_regprocedure('public.increment_install_count(uuid)') is null
    or to_regprocedure('public.notify_new_submission()') is null
    or to_regprocedure('public.notify_new_report()') is null
    or (
      select count(*) from pg_trigger
      where tgname in (
        'submissions_notify_after_insert',
        'skill_reports_notify_after_insert'
      ) and not tgisinternal
    ) <> 2 then
    raise exception 'pre-014 fixture is missing an obsolete write path';
  end if;

  if not has_table_privilege('anon', 'public.submissions', 'insert')
    or not has_table_privilege('authenticated', 'public.skill_reports', 'insert')
    or exists (
      select 1 from pg_constraint
      where conrelid = 'public.skills'::regclass
        and conname = 'skills_install_count_nonnegative'
    )
    or exists (
      select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = 'skills'
        and column_name in ('published_at', 'skill_md_summary_zh')
    ) then
    raise exception 'pre-014 fixture does not expose the expected upgrade work';
  end if;

  if not exists (
    select 1 from public.skills where install_count is null
  ) or (select count(*) from auth.users where id in (
    '00000000-0000-4000-8000-000000000211',
    '00000000-0000-4000-8000-000000000212'
  )) <> 2 then
    raise exception 'pre-014 fixture is missing historical data';
  end if;
end;
$$;

commit;
