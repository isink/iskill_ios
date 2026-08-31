-- Run only against a disposable local database after loading the schema.
-- psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security.sql

begin;

do $$
declare
  primary_key_columns text[];
begin
  if (
    select relrowsecurity
    from pg_class
    where oid = 'public.favorites'::regclass
  ) is distinct from true then
    raise exception 'favorites must have row level security enabled';
  end if;

  if (
    select count(*)
    from pg_policies
    where schemaname = 'public' and tablename = 'favorites'
  ) <> 1
    or not exists (
      select 1
      from pg_policies
      where schemaname = 'public'
        and tablename = 'favorites'
        and policyname = 'favorites owner'
        and cmd = 'ALL'
        and roles = array['authenticated']::name[]
    ) then
    raise exception 'favorites must have exactly one authenticated owner policy';
  end if;

  if has_table_privilege('anon', 'public.favorites', 'select')
    or has_table_privilege('anon', 'public.favorites', 'insert')
    or has_table_privilege('anon', 'public.favorites', 'update')
    or has_table_privilege('anon', 'public.favorites', 'delete') then
    raise exception 'anon must not access favorites';
  end if;

  if not has_table_privilege('authenticated', 'public.favorites', 'select')
    or not has_table_privilege('authenticated', 'public.favorites', 'insert')
    or not has_table_privilege('authenticated', 'public.favorites', 'update')
    or not has_table_privilege('authenticated', 'public.favorites', 'delete')
    or has_table_privilege('authenticated', 'public.favorites', 'truncate')
    or has_table_privilege('authenticated', 'public.favorites', 'references')
    or has_table_privilege('authenticated', 'public.favorites', 'trigger') then
    raise exception 'authenticated favorites grants are incomplete';
  end if;

  if not has_table_privilege('service_role', 'public.favorites', 'select')
    or not has_table_privilege('service_role', 'public.favorites', 'insert')
    or not has_table_privilege('service_role', 'public.favorites', 'update')
    or not has_table_privilege('service_role', 'public.favorites', 'delete')
    or has_table_privilege('service_role', 'public.favorites', 'truncate')
    or has_table_privilege('service_role', 'public.favorites', 'references')
    or has_table_privilege('service_role', 'public.favorites', 'trigger') then
    raise exception 'service_role favorites grants are incomplete';
  end if;

  if not has_table_privilege('anon', 'public.skills', 'select')
    or has_table_privilege('anon', 'public.skills', 'insert')
    or has_table_privilege('anon', 'public.skills', 'update')
    or has_table_privilege('anon', 'public.skills', 'delete')
    or not has_table_privilege('authenticated', 'public.skills', 'select')
    or has_table_privilege('authenticated', 'public.skills', 'insert')
    or has_table_privilege('authenticated', 'public.skills', 'update')
    or has_table_privilege('authenticated', 'public.skills', 'delete')
    or not has_table_privilege('anon', 'public.categories', 'select')
    or has_table_privilege('anon', 'public.categories', 'insert')
    or has_table_privilege('anon', 'public.categories', 'update')
    or has_table_privilege('anon', 'public.categories', 'delete')
    or not has_table_privilege('authenticated', 'public.categories', 'select')
    or has_table_privilege('authenticated', 'public.categories', 'insert')
    or has_table_privilege('authenticated', 'public.categories', 'update')
    or has_table_privilege('authenticated', 'public.categories', 'delete') then
    raise exception 'client skills and categories grants must be read only';
  end if;

  if has_table_privilege('anon', 'public.submissions', 'select')
    or has_table_privilege('anon', 'public.submissions', 'insert')
    or has_table_privilege('anon', 'public.submissions', 'update')
    or has_table_privilege('anon', 'public.submissions', 'delete')
    or has_table_privilege('authenticated', 'public.submissions', 'select')
    or has_table_privilege('authenticated', 'public.submissions', 'insert')
    or has_table_privilege('authenticated', 'public.submissions', 'update')
    or has_table_privilege('authenticated', 'public.submissions', 'delete')
    or has_table_privilege('authenticated', 'public.submissions', 'truncate')
    or has_table_privilege('authenticated', 'public.submissions', 'references')
    or has_table_privilege('authenticated', 'public.submissions', 'trigger') then
    raise exception 'client roles must not access submissions';
  end if;

  if not has_table_privilege('service_role', 'public.submissions', 'select')
    or has_table_privilege('service_role', 'public.submissions', 'update')
    or has_table_privilege('service_role', 'public.submissions', 'insert')
    or has_table_privilege('service_role', 'public.submissions', 'delete')
    or has_table_privilege('service_role', 'public.submissions', 'truncate')
    or has_table_privilege('service_role', 'public.submissions', 'references')
    or has_table_privilege('service_role', 'public.submissions', 'trigger')
    or not has_column_privilege(
      'service_role', 'public.submissions', 'agent_decision', 'update'
    )
    or not has_column_privilege(
      'service_role', 'public.submissions', 'agent_reason', 'update'
    )
    or not has_column_privilege(
      'service_role', 'public.submissions', 'agent_reviewed_at', 'update'
    )
    or has_column_privilege('service_role', 'public.submissions', 'status', 'update')
    or has_column_privilege('service_role', 'public.submissions', 'health', 'update')
    or has_column_privilege(
      'service_role', 'public.submissions', 'reviewer_note', 'update'
    ) then
    raise exception 'service_role submissions grants exceed recommendation fields';
  end if;

  if exists (
    select 1
    from pg_attribute as column_definition
    where column_definition.attrelid = 'public.submissions'::regclass
      and column_definition.attnum > 0
      and not column_definition.attisdropped
      and has_column_privilege(
        'service_role',
        'public.submissions',
        column_definition.attname,
        'update'
      ) is distinct from (
        column_definition.attname = any(
          array['agent_decision', 'agent_reason', 'agent_reviewed_at']::text[]
        )
      )
  ) then
    raise exception 'service_role submissions column grants are not exact';
  end if;

  if has_table_privilege('anon', 'public.skill_reports', 'select')
    or has_table_privilege('anon', 'public.skill_reports', 'insert')
    or has_table_privilege('anon', 'public.skill_reports', 'update')
    or has_table_privilege('anon', 'public.skill_reports', 'delete')
    or has_table_privilege('authenticated', 'public.skill_reports', 'select')
    or has_table_privilege('authenticated', 'public.skill_reports', 'insert')
    or has_table_privilege('authenticated', 'public.skill_reports', 'update')
    or has_table_privilege('authenticated', 'public.skill_reports', 'delete')
    or has_table_privilege('authenticated', 'public.skill_reports', 'truncate')
    or has_table_privilege('authenticated', 'public.skill_reports', 'references')
    or has_table_privilege('authenticated', 'public.skill_reports', 'trigger') then
    raise exception 'reports must be isolated from direct client access';
  end if;

  if not has_table_privilege('service_role', 'public.skill_reports', 'select')
    or has_table_privilege('service_role', 'public.skill_reports', 'insert')
    or has_table_privilege('service_role', 'public.skill_reports', 'update')
    or has_table_privilege('service_role', 'public.skill_reports', 'delete')
    or has_table_privilege('service_role', 'public.skill_reports', 'truncate')
    or has_table_privilege('service_role', 'public.skill_reports', 'references')
    or has_table_privilege('service_role', 'public.skill_reports', 'trigger') then
    raise exception 'service_role reports grant must be select only';
  end if;

  if has_function_privilege('anon', 'public.submit_skill_report(uuid,text,text)', 'execute')
    or not has_function_privilege(
      'authenticated', 'public.submit_skill_report(uuid,text,text)', 'execute'
    )
    or has_function_privilege(
      'service_role', 'public.submit_skill_report(uuid,text,text)', 'execute'
    ) then
    raise exception 'submit_skill_report grants are incorrect';
  end if;

  if has_function_privilege('anon', 'public.delete_my_account()', 'execute')
    or not has_function_privilege(
      'authenticated', 'public.delete_my_account()', 'execute'
    )
    or has_function_privilege(
      'service_role', 'public.delete_my_account()', 'execute'
    ) then
    raise exception 'delete_my_account grants are incorrect';
  end if;

  if not has_function_privilege(
      'anon', 'public.get_new_counts_by_category(timestamptz)', 'execute'
    )
    or not has_function_privilege(
      'authenticated', 'public.get_new_counts_by_category(timestamptz)', 'execute'
    )
    or has_function_privilege(
      'service_role', 'public.get_new_counts_by_category(timestamptz)', 'execute'
    )
    or not has_function_privilege(
      'anon', 'public.get_repo_groups(text,integer,integer)', 'execute'
    )
    or not has_function_privilege(
      'authenticated', 'public.get_repo_groups(text,integer,integer)', 'execute'
    )
    or has_function_privilege(
      'service_role', 'public.get_repo_groups(text,integer,integer)', 'execute'
    )
    or not has_function_privilege(
      'anon', 'public.get_category_counts()', 'execute'
    )
    or not has_function_privilege(
      'authenticated', 'public.get_category_counts()', 'execute'
    )
    or has_function_privilege(
      'service_role', 'public.get_category_counts()', 'execute'
    ) then
    raise exception 'read RPC grants are incorrect';
  end if;

  if has_function_privilege(
      'anon', 'public.apply_submission_decision(uuid,text,text,jsonb,jsonb)', 'execute'
    )
    or has_function_privilege(
      'authenticated', 'public.apply_submission_decision(uuid,text,text,jsonb,jsonb)',
      'execute'
    )
    or not has_function_privilege(
      'service_role', 'public.apply_submission_decision(uuid,text,text,jsonb,jsonb)',
      'execute'
    ) then
    raise exception 'apply_submission_decision grants are incorrect';
  end if;

  if has_function_privilege(
      'anon', 'public.apply_skill_overrides(text[],jsonb,jsonb,boolean)', 'execute'
    )
    or has_function_privilege(
      'authenticated', 'public.apply_skill_overrides(text[],jsonb,jsonb,boolean)',
      'execute'
    )
    or not has_function_privilege(
      'service_role', 'public.apply_skill_overrides(text[],jsonb,jsonb,boolean)',
      'execute'
    ) then
    raise exception 'apply_skill_overrides grants are incorrect';
  end if;

  if has_function_privilege(
      'anon',
      'public.fill_skill_enrichment(uuid,timestamptz,text,text[],text[],text)',
      'execute'
    )
    or has_function_privilege(
      'authenticated',
      'public.fill_skill_enrichment(uuid,timestamptz,text,text[],text[],text)',
      'execute'
    )
    or not has_function_privilege(
      'service_role',
      'public.fill_skill_enrichment(uuid,timestamptz,text,text[],text[],text)',
      'execute'
    ) then
    raise exception 'fill_skill_enrichment grants are incorrect';
  end if;

  if not exists (
    select 1
    from pg_proc as function_definition
    where function_definition.oid =
      to_regprocedure('public.submit_skill_report(uuid,text,text)')
      and function_definition.prosecdef
      and exists (
        select 1
        from unnest(coalesce(function_definition.proconfig, array[]::text[])) as setting(value)
        where setting.value in ('search_path=', 'search_path=""')
      )
      and position(
        'pg_advisory_xact_lock'
        in pg_get_functiondef(function_definition.oid)
      ) > 0
  ) then
    raise exception 'submit_skill_report must be locked security definer with empty search_path';
  end if;

  if not exists (
    select 1
    from pg_proc as function_definition
    where function_definition.oid = to_regprocedure('public.delete_my_account()')
      and function_definition.prosecdef
      and exists (
        select 1
        from unnest(coalesce(function_definition.proconfig, array[]::text[])) as setting(value)
        where setting.value in ('search_path=', 'search_path=""')
      )
  ) then
    raise exception 'delete_my_account must be security definer with empty search_path';
  end if;

  if not exists (
    select 1
    from pg_proc as function_definition
    where function_definition.oid =
      to_regprocedure('public.apply_submission_decision(uuid,text,text,jsonb,jsonb)')
      and function_definition.prosecdef
      and exists (
        select 1
        from unnest(coalesce(function_definition.proconfig, array[]::text[])) as setting(value)
        where setting.value in ('search_path=', 'search_path=""')
      )
  ) then
    raise exception 'apply_submission_decision must be security definer with empty search_path';
  end if;

  if not exists (
    select 1
    from pg_proc as function_definition
    where function_definition.oid =
      to_regprocedure('public.apply_skill_overrides(text[],jsonb,jsonb,boolean)')
      and function_definition.prosecdef
      and function_definition.prorettype = 'jsonb'::regtype
      and exists (
        select 1
        from unnest(coalesce(function_definition.proconfig, array[]::text[])) as setting(value)
        where setting.value in ('search_path=', 'search_path=""')
      )
  ) then
    raise exception 'apply_skill_overrides must be security definer with empty search_path';
  end if;

  if not exists (
    select 1
    from pg_proc as function_definition
    where function_definition.oid = to_regprocedure(
        'public.fill_skill_enrichment(uuid,timestamptz,text,text[],text[],text)'
      )
      and function_definition.prosecdef
      and function_definition.prorettype = 'boolean'::regtype
      and exists (
        select 1
        from unnest(coalesce(function_definition.proconfig, array[]::text[])) as setting(value)
        where setting.value in ('search_path=', 'search_path=""')
      )
  ) then
    raise exception 'fill_skill_enrichment must be security definer with empty search_path';
  end if;

  if exists (
    select 1
    from unnest(array[
      'public.get_new_counts_by_category(timestamptz)'::regprocedure,
      'public.get_category_counts()'::regprocedure,
      'public.get_repo_groups(text,integer,integer)'::regprocedure
    ]) as read_rpc(oid)
    join pg_proc as function_definition on function_definition.oid = read_rpc.oid
    where function_definition.prosecdef
      or function_definition.provolatile <> 's'
      or not exists (
        select 1
        from unnest(coalesce(function_definition.proconfig, array[]::text[])) as setting(value)
        where setting.value in ('search_path=', 'search_path=""')
      )
  ) then
    raise exception 'read RPCs must be stable invokers with empty search_path';
  end if;

  if to_regprocedure('public.increment_install_count(uuid)') is not null then
    raise exception 'increment_install_count must not exist';
  end if;

  if to_regprocedure('public.notify_new_submission()') is not null
    or to_regprocedure('public.notify_new_report()') is not null then
    raise exception 'external notification functions must not exist';
  end if;

  if exists (
    select 1
    from pg_trigger
    where tgrelid in (
      'public.submissions'::regclass,
      'public.skill_reports'::regclass
    )
      and not tgisinternal
  ) then
    raise exception 'submissions and reports must not have user triggers';
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename in ('submissions', 'skill_reports')
  ) then
    raise exception 'submissions and skill_reports must not have client policies';
  end if;

  if (
    select atttypid
    from pg_attribute
    where attrelid = 'public.favorites'::regclass
      and attname = 'user_id'
      and not attisdropped
  ) is distinct from 'uuid'::regtype
    or (
      select atttypid
      from pg_attribute
      where attrelid = 'public.favorites'::regclass
        and attname = 'skill_id'
        and not attisdropped
    ) is distinct from 'uuid'::regtype then
    raise exception 'favorites identifiers must use uuid';
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
    raise exception 'favorites primary key must be (user_id, skill_id)';
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
    raise exception 'favorites user_id cascade foreign key is missing';
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
    raise exception 'favorites skill_id cascade foreign key is missing';
  end if;

  if (
    select count(*)
    from pg_constraint
    where conrelid = 'public.favorites'::regclass
      and contype = 'f'
  ) <> 2 then
    raise exception 'favorites must have exactly two foreign keys';
  end if;

  if (
    select atttypid from pg_attribute
    where attrelid = 'public.skills'::regclass
      and attname = 'published_at' and not attisdropped
  ) is distinct from 'timestamptz'::regtype
    or (
      select atttypid from pg_attribute
      where attrelid = 'public.skills'::regclass
        and attname = 'skill_md_summary_zh' and not attisdropped
    ) is distinct from 'text'::regtype
    or (
      select atttypid from pg_attribute
      where attrelid = 'public.skills'::regclass
        and attname = 'use_cases_en' and not attisdropped
    ) is distinct from 'text[]'::regtype
    or (
      select atttypid from pg_attribute
      where attrelid = 'public.skills'::regclass
        and attname = 'install_count' and not attisdropped
    ) is distinct from 'integer'::regtype then
    raise exception 'skills compatibility column types are incorrect';
  end if;

  if (
    select attnotnull from pg_attribute
    where attrelid = 'public.skills'::regclass
      and attname = 'use_cases_en' and not attisdropped
  ) is distinct from true
    or (
      select attnotnull from pg_attribute
      where attrelid = 'public.skills'::regclass
        and attname = 'install_count' and not attisdropped
    ) is distinct from true then
    raise exception 'skills non-null contracts are missing';
  end if;

  if exists (
    select 1 from public.skills
    where install_count < 0 or use_cases_en is null
  ) then
    raise exception 'skills compatibility data violates its contract';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.skills'::regclass
      and conname = 'skills_install_count_nonnegative'
      and contype = 'c'
      and convalidated
  ) then
    raise exception 'skills install_count check is missing or unvalidated';
  end if;
end;
$$;

-- Transactional behavior checks. The surrounding rollback keeps even a
-- successful run from leaving fixtures behind in the disposable database.
do $$
declare
  test_skill_id uuid := '00000000-0000-4000-8000-000000000101';
  partial_skill_id uuid := '00000000-0000-4000-8000-000000000103';
  test_submission_id uuid := '00000000-0000-4000-8000-000000000102';
  test_user_id uuid := '00000000-0000-4000-8000-000000000111';
  other_user_id uuid := '00000000-0000-4000-8000-000000000112';
begin
  insert into public.categories (slug, name)
  values ('security-test-category', 'Security Test');

  insert into public.skills (
    id, slug, name, category, description_zh, rank, featured, updated_at
  ) values (
    test_skill_id,
    'security-test-skill',
    'Security Test Skill',
    'security-test-category',
    repeat('保', 50),
    7,
    false,
    '2000-01-01 00:00:00+00'
  );

  insert into public.skills (
    id, slug, name, category, description_zh, use_cases,
    skill_md_summary_zh, updated_at
  ) values (
    partial_skill_id,
    'security-test-partial-skill',
    'Security Test Partial Skill',
    'security-test-category',
    repeat('保', 50),
    array['代码审查', '文档生成', '数据分析'],
    repeat('保', 150),
    '2000-01-01 00:00:00+00'
  );

  insert into public.submissions (id, github_url)
  values (test_submission_id, 'https://github.com/example/security-test');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',
      test_user_id,
      'authenticated',
      'authenticated',
      'security-owner@example.invalid',
      '',
      now(),
      '{}',
      '{}',
      now(),
      now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      other_user_id,
      'authenticated',
      'authenticated',
      'security-other@example.invalid',
      '',
      now(),
      '{}',
      '{}',
      now(),
      now()
    );

  insert into public.favorites (user_id, skill_id) values
    (test_user_id, test_skill_id),
    (other_user_id, partial_skill_id);

  if not exists (
    select 1 from public.skills
    where id = test_skill_id and install_count = 0
  ) then
    raise exception 'skills install_count default is not zero';
  end if;

  begin
    insert into public.skills (slug, name, category, install_count)
    values ('security-test-negative', 'Negative', 'security-test-category', -1);
    raise exception 'negative install count unexpectedly succeeded';
  exception when check_violation then
    null;
  end;
end;
$$;

set local role anon;

do $$
begin
  if (
    select count
    from public.get_new_counts_by_category('2000-01-01 00:00:00+00')
    where category = 'security-test-category'
  ) is distinct from 2::bigint
    or (
      select count
      from public.get_category_counts()
      where category = 'security-test-category'
    ) is distinct from 2::bigint then
    raise exception 'anon read-count RPC results are incorrect';
  end if;

  if exists (
    select 1
    from public.get_new_counts_by_category('3000-01-01 00:00:00+00')
    where category = 'security-test-category'
  ) then
    raise exception 'anon count RPC ignored its time cutoff';
  end if;

  if not exists (
    select 1
    from public.get_repo_groups('security-test-category', 0, 50)
    where repo = ''
      and author = ''
      and skill_count = 2
      and rep_skill_id = '00000000-0000-4000-8000-000000000101'
  ) then
    raise exception 'anon repo-group RPC result is incorrect';
  end if;

  if exists (
    select 1
    from public.get_repo_groups('missing-security-category', 0, 50)
  ) then
    raise exception 'anon repo-group RPC ignored its category filter';
  end if;

  begin
    perform count(*) from public.favorites;
    raise exception 'anon unexpectedly read favorites';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-4000-8000-000000000111',
  true
);

do $$
begin
  if (select count(*) from public.favorites) <> 1
    or not exists (
      select 1 from public.favorites
      where user_id = '00000000-0000-4000-8000-000000000111'
    ) then
    raise exception 'favorites owner policy exposed another account';
  end if;

  begin
    insert into public.favorites (user_id, skill_id)
    values (
      '00000000-0000-4000-8000-000000000112',
      '00000000-0000-4000-8000-000000000101'
    );
    raise exception 'favorites owner policy accepted a cross-account write';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

select public.delete_my_account();
reset role;

do $$
begin
  if exists (
    select 1 from auth.users
    where id = '00000000-0000-4000-8000-000000000111'
  ) or exists (
    select 1 from public.favorites
    where user_id = '00000000-0000-4000-8000-000000000111'
  ) or not exists (
    select 1 from auth.users
    where id = '00000000-0000-4000-8000-000000000112'
  ) then
    raise exception 'delete_my_account did not delete only the current account';
  end if;
end;
$$;

set local role service_role;

do $$
declare
  test_skill_id uuid := '00000000-0000-4000-8000-000000000101';
  partial_skill_id uuid := '00000000-0000-4000-8000-000000000103';
  test_submission_id uuid := '00000000-0000-4000-8000-000000000102';
  source_version timestamptz;
  partial_source_version timestamptz;
  override_result jsonb;
begin
  select updated_at into source_version
  from public.skills where id = test_skill_id;
  if not public.fill_skill_enrichment(
    test_skill_id,
    source_version,
    repeat('文', 50),
    array['代码审查', '文档生成', '数据分析'],
    array['Code Review', 'Docs', 'Data Analysis'],
    repeat('文', 150)
  ) then
    raise exception 'fill_skill_enrichment unexpectedly skipped current source';
  end if;

  if not exists (
    select 1 from public.skills
    where id = test_skill_id
      and description_zh = repeat('保', 50)
      and use_cases = array['代码审查', '文档生成', '数据分析']::text[]
      and use_cases_en = array['Code Review', 'Docs', 'Data Analysis']::text[]
      and skill_md_summary_zh = repeat('文', 150)
  ) then
    raise exception 'fill_skill_enrichment overwrote existing data or missed empty fields';
  end if;

  if public.fill_skill_enrichment(
    test_skill_id,
    source_version,
    repeat('新', 50),
    array['安全检查', '内容撰写', '报表分析'],
    array['Security Review', 'Writing', 'Reports'],
    repeat('新', 150)
  ) then
    raise exception 'fill_skill_enrichment accepted a stale source version';
  end if;

  select updated_at into partial_source_version
  from public.skills where id = partial_skill_id;
  if not public.fill_skill_enrichment(
    partial_skill_id,
    partial_source_version,
    repeat('文', 50),
    array['代码审查', '文档生成', '数据分析'],
    array['Code Review', 'Docs', 'Data Analysis'],
    repeat('文', 150)
  ) then
    raise exception 'fill_skill_enrichment skipped partial bilingual repair';
  end if;

  if not exists (
    select 1 from public.skills
    where id = partial_skill_id
      and use_cases = array['代码审查', '文档生成', '数据分析']::text[]
      and use_cases_en = array['Code Review', 'Docs', 'Data Analysis']::text[]
  ) then
    raise exception 'fill_skill_enrichment did not repair bilingual tags as one pair';
  end if;

  begin
    perform public.apply_skill_overrides(
      array['security-test-skill', 'missing-skill'],
      '{"security-test-skill": 99}'::jsonb,
      '{"security-test-skill": "security-test-category"}'::jsonb,
      true
    );
    raise exception 'strict missing override unexpectedly succeeded';
  exception when sqlstate '22023' then
    null;
  end;

  if not exists (
    select 1 from public.skills
    where id = test_skill_id and not featured and rank = 7
  ) then
    raise exception 'strict missing override partially changed existing rows';
  end if;

  begin
    perform public.apply_skill_overrides(
      array['security-test-skill'],
      '{"security-test-skill": 99}'::jsonb,
      '{"security-test-skill": "missing-category"}'::jsonb,
      false
    );
    raise exception 'invalid category override unexpectedly succeeded';
  exception when sqlstate '22023' then
    null;
  end;

  if not exists (
    select 1 from public.skills
    where id = test_skill_id and not featured and rank = 7
  ) then
    raise exception 'failed override did not roll back earlier updates';
  end if;

  override_result := public.apply_skill_overrides(
    array['security-test-skill', 'missing-skill'],
    '{"security-test-skill": 88}'::jsonb,
    '{}'::jsonb,
    false
  );
  if override_result -> 'missing_slugs' is distinct from '["missing-skill"]'::jsonb
    or override_result ->> 'featured_applied' is distinct from '1'
    or override_result ->> 'ranks_applied' is distinct from '1' then
    raise exception 'apply_skill_overrides result does not expose applied and missing rows';
  end if;

  begin
    perform public.apply_submission_decision(
      test_submission_id,
      null,
      null,
      null,
      '[]'::jsonb
    );
    raise exception 'null submission decision unexpectedly succeeded';
  exception when sqlstate '22023' then
    null;
  end;

  if not exists (
    select 1 from public.submissions
    where id = test_submission_id and status = 'pending'
  ) then
    raise exception 'null submission decision changed submission state';
  end if;
end;
$$;

reset role;

rollback;
