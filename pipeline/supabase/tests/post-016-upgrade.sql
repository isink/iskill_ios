begin;

do $$
begin
  if not exists (
    select 1
    from public.skills
    where id = '00000000-0000-4000-8000-000000000202'
      and slug = 'pre-014-skill'
      and install_count = 0
      and use_cases_en = '{}'::text[]
      and updated_at = '2026-01-02 00:00:00+00'
  ) then
    raise exception '014-016 did not preserve and backfill the pre-014 skill';
  end if;

  if not exists (
    select 1
    from public.skills
    where id = '00000000-0000-4000-8000-000000000203'
      and install_count = 7
      and updated_at = '2026-01-03 00:00:00+00'
  ) then
    raise exception '014-016 changed an existing positive install count';
  end if;

  if not exists (
    select 1 from public.favorites
    where user_id = '00000000-0000-4000-8000-000000000211'
      and skill_id = '00000000-0000-4000-8000-000000000202'
  ) then
    raise exception '014-016 did not preserve the historical favorite';
  end if;

  if not exists (
    select 1 from public.submissions
    where id = '00000000-0000-4000-8000-000000000221'
      and submitter_user_id = '00000000-0000-4000-8000-000000000212'
      and note = 'pre-014 submission'
  ) or not exists (
    select 1 from public.skill_reports
    where id = '00000000-0000-4000-8000-000000000222'
      and reporter_user_id = '00000000-0000-4000-8000-000000000212'
      and note = 'pre-014 report'
  ) then
    raise exception '016 did not preserve historical submission or report rows';
  end if;

  if to_regprocedure('public.increment_install_count(uuid)') is not null
    or to_regprocedure('public.notify_new_submission()') is not null
    or to_regprocedure('public.notify_new_report()') is not null then
    raise exception '016 left an obsolete public function behind';
  end if;

  if (
    select count
    from public.get_new_counts_by_category('2025-12-31 00:00:00+00')
    where category = 'pre-014-category'
  ) is distinct from 2::bigint then
    raise exception '015 left get_new_counts_by_category unusable or incorrect';
  end if;

  if exists (
    select 1
    from public.get_new_counts_by_category('2026-01-01 00:00:00+00')
    where category = 'pre-014-category'
  ) then
    raise exception 'get_new_counts_by_category ignored its strict time cutoff';
  end if;

  if not exists (
    select 1
    from public.get_repo_groups('pre-014-category', 0, 50)
    where repo = 'fixture-owner/fixture-repo'
      and author = 'fixture-owner'
      and skill_count = 2
      and rep_skill_id = '00000000-0000-4000-8000-000000000203'
  ) then
    raise exception '015 left get_repo_groups unusable or incorrect';
  end if;

  if exists (
    select 1
    from public.get_repo_groups('missing-category', 0, 50)
  ) then
    raise exception 'get_repo_groups ignored its category filter';
  end if;
end;
$$;

insert into public.skills (slug, name, category)
values ('post-016-default', 'Post-016 Default', 'pre-014-category');

do $$
begin
  if not exists (
    select 1 from public.skills
    where slug = 'post-016-default' and install_count = 0
  ) then
    raise exception '015 did not install the zero install-count default';
  end if;

  begin
    insert into public.skills (slug, name, category, install_count)
    values ('post-016-negative', 'Post-016 Negative', 'pre-014-category', -1);
    raise exception 'negative install count unexpectedly succeeded';
  exception when check_violation then
    null;
  end;
end;
$$;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-4000-8000-000000000211',
  true
);
select public.delete_my_account();
reset role;

do $$
begin
  if exists (
    select 1 from auth.users
    where id = '00000000-0000-4000-8000-000000000211'
  ) or exists (
    select 1 from public.favorites
    where user_id = '00000000-0000-4000-8000-000000000211'
  ) then
    raise exception 'delete_my_account did not cascade through historical favorites';
  end if;
end;
$$;

rollback;
