begin;

-- The submission UI no longer exists. Keep historical rows for the service-role
-- review pipeline, but remove every client-facing table permission and policy.
alter table public.submissions enable row level security;
drop policy if exists "submissions insert anon" on public.submissions;
drop policy if exists "submissions insert" on public.submissions;
drop policy if exists "submissions select own" on public.submissions;
revoke all on table public.submissions from public, anon, authenticated, service_role;
grant select on table public.submissions to service_role;
grant update (agent_decision, agent_reason, agent_reviewed_at)
  on table public.submissions to service_role;

drop trigger if exists submissions_notify_after_insert on public.submissions;
drop function if exists public.notify_new_submission();

-- Reports are accepted only through submit_skill_report(). The function derives
-- identity and skill metadata server-side and applies bounded abuse controls.
alter table public.skill_reports enable row level security;
drop policy if exists "skill_reports insert" on public.skill_reports;

do $$
declare
  existing_policy record;
begin
  for existing_policy in
    select tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('submissions', 'skill_reports')
  loop
    execute format(
      'drop policy %I on public.%I',
      existing_policy.policyname,
      existing_policy.tablename
    );
  end loop;
end;
$$;

revoke all on table public.skill_reports from public, anon, authenticated, service_role;
grant select on table public.skill_reports to service_role;

drop trigger if exists skill_reports_notify_after_insert on public.skill_reports;
drop function if exists public.notify_new_report();

-- Installation count was driven by a copy action rather than a verified install.
-- Preserve the column for historical ranking, but remove the write RPC entirely.
drop function if exists public.increment_install_count(uuid);

-- Apply an agent decision and its skill rows in one database transaction. The
-- row lock and pending-state checks prevent duplicate or partial publication.
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
  -- A deterministic validator may decide an unclaimed row directly. Once an
  -- agent recommendation exists, only that exact decision can be applied.
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
      slug,
      name,
      description,
      category,
      tags,
      author,
      github_url,
      skill_md_content,
      rank,
      score,
      featured
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

revoke all on function public.apply_skill_overrides(text[], jsonb, jsonb, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.apply_skill_overrides(text[], jsonb, jsonb, boolean)
  to service_role;

-- Repair only fields that are still invalid at update time. The source version
-- prevents content generated from an older skill snapshot from being applied.
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

revoke all on function public.fill_skill_enrichment(uuid, timestamptz, text, text[], text[], text)
  from public, anon, authenticated, service_role;
grant execute on function public.fill_skill_enrichment(uuid, timestamptz, text, text[], text[], text)
  to service_role;

revoke all on function public.set_updated_at()
  from public, anon, authenticated, service_role;

commit;
