-- Skiller database schema snapshot.
-- Run only on a fresh Supabase project; existing projects use migrations/.

begin;

create extension if not exists "uuid-ossp";
create extension if not exists pg_trgm;

create table if not exists public.categories (
  id uuid primary key default uuid_generate_v4(),
  slug text not null unique,
  name text not null,
  icon text not null default 'sparkles',
  created_at timestamptz not null default now()
);

create table if not exists public.skills (
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
  skill_md_summary_zh text,
  github_stars integer,
  install_count integer not null default 0
    constraint skills_install_count_nonnegative check (install_count >= 0),
  rank integer not null default 0,
  score integer not null default 0,
  featured boolean not null default false,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists skills_category_idx on public.skills (category);
create index if not exists skills_rank_idx on public.skills (rank desc);
create index if not exists skills_featured_idx on public.skills (featured) where featured = true;
create index if not exists skills_name_trgm_idx on public.skills using gin (name gin_trgm_ops);

create table if not exists public.favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  skill_id uuid not null references public.skills(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, skill_id)
);

create table if not exists public.submissions (
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

create index if not exists submissions_status_idx
  on public.submissions (status, created_at desc);
create index if not exists submissions_user_idx
  on public.submissions (submitter_user_id, created_at desc);
create index if not exists submissions_pending_no_agent_idx
  on public.submissions (created_at)
  where status = 'pending' and agent_decision is null;

create table if not exists public.skill_reports (
  id uuid primary key default uuid_generate_v4(),
  skill_id text not null,
  skill_slug text,
  skill_name text,
  reason text not null,
  note text,
  reporter_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists skill_reports_created_idx
  on public.skill_reports (created_at desc);
create index if not exists skill_reports_skill_idx
  on public.skill_reports (skill_id);
create index if not exists skill_reports_reporter_created_idx
  on public.skill_reports (reporter_user_id, created_at desc);

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

alter table public.skills enable row level security;
alter table public.categories enable row level security;
alter table public.favorites enable row level security;
alter table public.submissions enable row level security;
alter table public.skill_reports enable row level security;

drop policy if exists "skills read" on public.skills;
create policy "skills read" on public.skills
  for select to anon, authenticated using (true);

drop policy if exists "categories read" on public.categories;
create policy "categories read" on public.categories
  for select to anon, authenticated using (true);

drop policy if exists "favorites owner" on public.favorites;
create policy "favorites owner" on public.favorites
  for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on table public.skills from public, anon, authenticated, service_role;
grant select on table public.skills to anon, authenticated;
grant all on table public.skills to service_role;

revoke all on table public.categories from public, anon, authenticated, service_role;
grant select on table public.categories to anon, authenticated;
grant all on table public.categories to service_role;

revoke all on table public.favorites from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.favorites to authenticated;
grant select, insert, update, delete on table public.favorites to service_role;

revoke all on table public.submissions from public, anon, authenticated, service_role;
grant select on table public.submissions to service_role;
grant update (agent_decision, agent_reason, agent_reviewed_at)
  on table public.submissions to service_role;

revoke all on table public.skill_reports from public, anon, authenticated, service_role;
grant select on table public.skill_reports to service_role;

create or replace function public.get_new_counts_by_category(since timestamptz)
returns table(category text, count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select skill.category, count(*)
  from public.skills as skill
  where skill.created_at > since
  group by skill.category;
$$;

create or replace function public.get_category_counts()
returns table(category text, count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select skill.category, count(*)
  from public.skills as skill
  group by skill.category;
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
security invoker
set search_path = ''
as $$
  with base as (
    select
      regexp_replace(skill.github_url, '^https?://github\.com/([^/]+/[^/]+).*$', '\1') as g_repo,
      skill.author,
      skill.github_stars,
      skill.id,
      skill.featured,
      skill.rank,
      skill.install_count
    from public.skills as skill
    where p_category is null or skill.category = p_category
  ), ranked as (
    select
      base.g_repo,
      base.author,
      base.github_stars,
      base.id,
      row_number() over (
        partition by base.g_repo
        order by base.featured desc, base.rank desc,
          base.install_count desc nulls last, base.id
      ) as row_number,
      count(*) over (partition by base.g_repo) as group_count
    from base
  )
  select
    ranked.g_repo,
    ranked.author,
    ranked.github_stars,
    ranked.group_count,
    ranked.id
  from ranked
  where ranked.row_number = 1
  order by ranked.github_stars desc nulls last, ranked.g_repo
  offset p_offset limit p_limit;
$$;

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

create or replace function public.submit_skill_report(
  p_skill_id uuid,
  p_reason text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  report_id uuid;
begin
  if uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if p_reason is null
    or p_reason not in ('abuse', 'copyright', 'malicious', 'spam', 'other') then
    raise exception 'Invalid report reason' using errcode = '22023';
  end if;
  if length(coalesce(p_note, '')) > 2000 then
    raise exception 'Report note is too long' using errcode = '22001';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('skill-report:' || uid::text, 0)
  );
  if (
    select count(*) from public.skill_reports as report
    where report.reporter_user_id = uid
      and report.created_at > now() - interval '1 hour'
  ) >= 10 then
    raise exception 'Report rate limit exceeded' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.skill_reports as report
    where report.reporter_user_id = uid
      and report.skill_id = p_skill_id::text
      and report.reason = p_reason
      and report.created_at > now() - interval '10 minutes'
  ) then
    raise exception 'Duplicate report' using errcode = 'P0001';
  end if;

  insert into public.skill_reports (
    skill_id, skill_slug, skill_name, reason, note, reporter_user_id
  )
  select
    skill.id::text,
    skill.slug,
    skill.name,
    p_reason,
    nullif(btrim(p_note), ''),
    uid
  from public.skills as skill
  where skill.id = p_skill_id
  returning id into report_id;

  if report_id is null then
    raise exception 'Skill not found' using errcode = '23503';
  end if;
  return report_id;
end;
$$;

create or replace function public.apply_submission_decision(
  p_submission_id uuid,
  p_decision text,
  p_reviewer_note text,
  p_health jsonb,
  p_skill_rows jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_status text;
  current_decision text;
begin
  if p_decision is null or p_decision not in ('approve', 'reject') then
    raise exception 'Invalid submission decision' using errcode = '22023';
  end if;

  select submission.status, submission.agent_decision
    into current_status, current_decision
  from public.submissions as submission
  where submission.id = p_submission_id
  for update;

  if not found then
    raise exception 'Submission not found' using errcode = 'P0002';
  end if;
  if current_status <> 'pending' then
    raise exception 'Submission is no longer pending' using errcode = 'P0001';
  end if;
  if current_decision is not null and current_decision <> p_decision then
    raise exception 'Submission decision changed' using errcode = 'P0001';
  end if;

  if p_decision = 'approve' then
    if jsonb_typeof(p_skill_rows) is distinct from 'array' then
      raise exception 'Approved submission requires a skill-row array' using errcode = '22023';
    end if;
    if jsonb_array_length(p_skill_rows) = 0 then
      raise exception 'Approved submission requires skill rows' using errcode = '22023';
    end if;

    insert into public.skills (
      slug, name, description, category, tags, author, github_url,
      skill_md_content, rank, score, featured
    )
    select
      row.slug,
      row.name,
      row.description,
      row.category,
      coalesce(array(select jsonb_array_elements_text(row.tags)), '{}'::text[]),
      row.author,
      row.github_url,
      row.skill_md_content,
      row.rank,
      row.score,
      row.featured
    from jsonb_to_recordset(p_skill_rows) as row(
      slug text,
      name text,
      description text,
      category text,
      tags jsonb,
      author text,
      github_url text,
      skill_md_content text,
      rank integer,
      score integer,
      featured boolean
    )
    on conflict (slug) do update set
      name = excluded.name,
      description = excluded.description,
      category = excluded.category,
      tags = excluded.tags,
      author = excluded.author,
      github_url = excluded.github_url,
      skill_md_content = excluded.skill_md_content,
      rank = excluded.rank,
      score = excluded.score,
      featured = excluded.featured,
      updated_at = now();
  end if;

  update public.submissions
  set status = case p_decision when 'approve' then 'approved' else 'rejected' end,
      reviewer_note = nullif(btrim(p_reviewer_note), ''),
      reviewed_at = now(),
      health = p_health
  where id = p_submission_id;
end;
$$;

revoke all on function public.set_updated_at()
  from public, anon, authenticated, service_role;

revoke all on function public.get_new_counts_by_category(timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function public.get_new_counts_by_category(timestamptz)
  to anon, authenticated;

revoke all on function public.get_category_counts()
  from public, anon, authenticated, service_role;
grant execute on function public.get_category_counts()
  to anon, authenticated;

revoke all on function public.get_repo_groups(text, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.get_repo_groups(text, integer, integer)
  to anon, authenticated;

revoke all on function public.delete_my_account()
  from public, anon, authenticated, service_role;
grant execute on function public.delete_my_account() to authenticated;

revoke all on function public.submit_skill_report(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.submit_skill_report(uuid, text, text)
  to authenticated;

revoke all on function public.apply_submission_decision(uuid, text, text, jsonb, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.apply_submission_decision(uuid, text, text, jsonb, jsonb)
  to service_role;

create or replace function public.apply_skill_overrides(
  p_featured_slugs text[],
  p_ranks jsonb,
  p_category_overrides jsonb,
  p_strict boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  override_slug text;
  override_value text;
  parsed_rank integer;
  featured_applied integer;
  ranks_applied integer;
  categories_applied integer;
  missing_slugs text[];
begin
  if p_strict is null
    or p_featured_slugs is null
    or exists (
      select 1
      from unnest(p_featured_slugs) as featured_slug
      where nullif(btrim(featured_slug), '') is null
    )
    or (
      select count(*) <> count(distinct featured_slug)
      from unnest(p_featured_slugs) as featured_slug
    ) then
    raise exception 'Invalid featured slugs' using errcode = '22023';
  end if;

  if jsonb_typeof(p_ranks) is distinct from 'object'
    or jsonb_typeof(p_category_overrides) is distinct from 'object' then
    raise exception 'Override maps must be JSON objects' using errcode = '22023';
  end if;

  select coalesce(array_agg(reference.slug order by reference.slug), array[]::text[])
    into missing_slugs
  from (
    select unnest(p_featured_slugs) as slug
    union
    select jsonb_object_keys(p_ranks) as slug
    union
    select jsonb_object_keys(p_category_overrides) as slug
  ) as reference
  where not exists (
    select 1 from public.skills as skill where skill.slug = reference.slug
  );

  if p_strict and cardinality(missing_slugs) > 0 then
    raise exception 'Override slugs not found: %', array_to_string(missing_slugs, ', ')
      using errcode = '22023';
  end if;

  update public.skills as skill
  set featured = (skill.slug = any(p_featured_slugs))
  where skill.featured is distinct from (skill.slug = any(p_featured_slugs));

  for override_slug, override_value in
    select key, value from jsonb_each_text(p_ranks)
  loop
    if nullif(btrim(override_slug), '') is null then
      raise exception 'Invalid rank slug' using errcode = '22023';
    end if;
    begin
      parsed_rank := override_value::integer;
    exception when invalid_text_representation or numeric_value_out_of_range then
      raise exception 'Invalid rank for %', override_slug using errcode = '22023';
    end;
    update public.skills set rank = parsed_rank where slug = override_slug;
  end loop;

  for override_slug, override_value in
    select key, value from jsonb_each_text(p_category_overrides)
  loop
    if nullif(btrim(override_slug), '') is null
      or not exists (
        select 1 from public.categories where slug = override_value
      ) then
      raise exception 'Invalid category override for %', override_slug
        using errcode = '22023';
    end if;
    update public.skills set category = override_value where slug = override_slug;
  end loop;

  select count(*) into featured_applied
  from public.skills as skill
  where skill.slug = any(p_featured_slugs);

  select count(*) into ranks_applied
  from public.skills as skill
  where skill.slug in (select jsonb_object_keys(p_ranks));

  select count(*) into categories_applied
  from public.skills as skill
  where skill.slug in (select jsonb_object_keys(p_category_overrides));

  return jsonb_build_object(
    'featured_applied', featured_applied,
    'ranks_applied', ranks_applied,
    'categories_applied', categories_applied,
    'missing_slugs', to_jsonb(missing_slugs)
  );
end;
$$;

create or replace function public.fill_skill_enrichment(
  p_skill_id uuid,
  p_source_updated_at timestamptz,
  p_description_zh text,
  p_use_cases text[],
  p_use_cases_en text[],
  p_skill_md_summary_zh text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_description_zh text;
  current_use_cases text[];
  current_use_cases_en text[];
  current_skill_md_summary_zh text;
  repair_use_case_pair boolean;
begin
  if p_source_updated_at is null
    or p_description_zh is null
    or p_use_cases is null
    or p_use_cases_en is null
    or p_skill_md_summary_zh is null
    or length(btrim(p_description_zh)) not between 50 and 80
    or length(btrim(p_skill_md_summary_zh)) not between 150 and 250
    or cardinality(p_use_cases) not between 3 and 5
    or cardinality(p_use_cases_en) <> cardinality(p_use_cases)
    or exists (
      select 1 from unnest(p_use_cases) as item
      where nullif(btrim(item), '') is null
        or length(btrim(item)) not between 4 and 8
    )
    or exists (
      select 1 from unnest(p_use_cases_en) as item
      where nullif(btrim(item), '') is null
        or cardinality(pg_catalog.regexp_split_to_array(btrim(item), '\s+'))
          not between 1 and 3
    ) then
    raise exception 'Invalid enrichment payload' using errcode = '22023';
  end if;

  select
    skill.description_zh,
    skill.use_cases,
    skill.use_cases_en,
    skill.skill_md_summary_zh
  into
    current_description_zh,
    current_use_cases,
    current_use_cases_en,
    current_skill_md_summary_zh
  from public.skills as skill
  where skill.id = p_skill_id
    and skill.updated_at = p_source_updated_at
  for update;

  if not found then
    return false;
  end if;

  repair_use_case_pair :=
    cardinality(coalesce(current_use_cases, '{}'::text[])) not between 3 and 5
    or cardinality(coalesce(current_use_cases_en, '{}'::text[])) not between 3 and 5
    or cardinality(coalesce(current_use_cases, '{}'::text[]))
      <> cardinality(coalesce(current_use_cases_en, '{}'::text[]))
    or exists (
      select 1 from unnest(coalesce(current_use_cases, '{}'::text[])) as item
      where nullif(btrim(item), '') is null
        or length(btrim(item)) not between 4 and 8
    )
    or exists (
      select 1 from unnest(coalesce(current_use_cases_en, '{}'::text[])) as item
      where nullif(btrim(item), '') is null
        or cardinality(pg_catalog.regexp_split_to_array(btrim(item), '\s+'))
          not between 1 and 3
    );

  update public.skills
  set description_zh = case
        when length(btrim(coalesce(current_description_zh, ''))) not between 50 and 80
          then btrim(p_description_zh)
        else description_zh
      end,
      use_cases = case
        when repair_use_case_pair then p_use_cases
        else use_cases
      end,
      use_cases_en = case
        when repair_use_case_pair then p_use_cases_en
        else use_cases_en
      end,
      skill_md_summary_zh = case
        when length(btrim(coalesce(current_skill_md_summary_zh, '')))
          not between 150 and 250
          then btrim(p_skill_md_summary_zh)
        else skill_md_summary_zh
      end
  where id = p_skill_id;

  return true;
end;
$$;

revoke all on function public.apply_skill_overrides(text[], jsonb, jsonb, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.apply_skill_overrides(text[], jsonb, jsonb, boolean)
  to service_role;

revoke all on function public.fill_skill_enrichment(uuid, timestamptz, text, text[], text[], text)
  from public, anon, authenticated, service_role;
grant execute on function public.fill_skill_enrichment(uuid, timestamptz, text, text[], text[], text)
  to service_role;

commit;
