begin;

alter table public.skills
  add column if not exists published_at timestamptz,
  add column if not exists skill_md_summary_zh text,
  add column if not exists install_count integer,
  add column if not exists use_cases_en text[];

do $$
begin
  if (
    select atttypid from pg_attribute
    where attrelid = 'public.skills'::regclass
      and attname = 'published_at'
      and not attisdropped
  ) is distinct from 'timestamptz'::regtype then
    raise exception 'public.skills.published_at must use timestamptz';
  end if;

  if (
    select atttypid from pg_attribute
    where attrelid = 'public.skills'::regclass
      and attname = 'skill_md_summary_zh'
      and not attisdropped
  ) is distinct from 'text'::regtype then
    raise exception 'public.skills.skill_md_summary_zh must use text';
  end if;

  if (
    select atttypid from pg_attribute
    where attrelid = 'public.skills'::regclass
      and attname = 'use_cases_en'
      and not attisdropped
  ) is distinct from 'text[]'::regtype then
    raise exception 'public.skills.use_cases_en must use text[]';
  end if;

  if (
    select atttypid from pg_attribute
    where attrelid = 'public.skills'::regclass
      and attname = 'install_count'
      and not attisdropped
  ) is distinct from 'integer'::regtype then
    raise exception 'public.skills.install_count must use integer';
  end if;

  if exists (select 1 from public.skills where install_count < 0) then
    raise exception 'public.skills.install_count contains negative values';
  end if;
end;
$$;

-- These are compatibility backfills, not source-content changes. Preserve the
-- content version used by the enrichment pipeline's stale-write protection.
alter table public.skills disable trigger skills_set_updated_at;
update public.skills set install_count = 0 where install_count is null;
update public.skills set use_cases_en = '{}' where use_cases_en is null;
alter table public.skills enable trigger skills_set_updated_at;

alter table public.skills
  alter column install_count set default 0,
  alter column install_count set not null,
  alter column use_cases_en set default '{}',
  alter column use_cases_en set not null;

alter table public.skills
  drop constraint if exists skills_install_count_nonnegative;
alter table public.skills
  add constraint skills_install_count_nonnegative check (install_count >= 0) not valid;
alter table public.skills
  validate constraint skills_install_count_nonnegative;

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

revoke all on table public.skills from public, anon, authenticated, service_role;
grant select on table public.skills to anon, authenticated;
grant all on table public.skills to service_role;

revoke all on table public.categories from public, anon, authenticated, service_role;
grant select on table public.categories to anon, authenticated;
grant all on table public.categories to service_role;

revoke all on function public.get_category_counts() from public, anon, authenticated, service_role;
grant execute on function public.get_category_counts() to anon, authenticated;

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

revoke all on function public.get_new_counts_by_category(timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function public.get_new_counts_by_category(timestamptz) to anon, authenticated;

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

revoke all on function public.get_repo_groups(text, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.get_repo_groups(text, integer, integer) to anon, authenticated;

create index if not exists skill_reports_reporter_created_idx
  on public.skill_reports (reporter_user_id, created_at desc);

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

  -- Serialize checks for one reporter so concurrent requests cannot bypass the
  -- hourly limit or duplicate window.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('skill-report:' || uid::text, 0)
  );

  if (
    select count(*)
    from public.skill_reports as report
    where report.reporter_user_id = uid
      and report.created_at > now() - interval '1 hour'
  ) >= 10 then
    raise exception 'Report rate limit exceeded' using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from public.skill_reports as report
    where report.reporter_user_id = uid
      and report.skill_id = p_skill_id::text
      and report.reason = p_reason
      and report.created_at > now() - interval '10 minutes'
  ) then
    raise exception 'Duplicate report' using errcode = 'P0001';
  end if;

  insert into public.skill_reports (
    skill_id,
    skill_slug,
    skill_name,
    reason,
    note,
    reporter_user_id
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

revoke all on function public.submit_skill_report(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.submit_skill_report(uuid, text, text)
  to authenticated;

commit;
