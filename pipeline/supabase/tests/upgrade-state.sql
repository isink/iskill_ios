select jsonb_build_object(
  'skills', coalesce((
    select jsonb_agg(to_jsonb(skill_state) order by skill_state.id)
    from (
      select
        id,
        slug,
        install_count,
        use_cases_en,
        published_at,
        skill_md_summary_zh,
        created_at,
        updated_at
      from public.skills
      where id in (
        '00000000-0000-4000-8000-000000000202',
        '00000000-0000-4000-8000-000000000203'
      )
    ) as skill_state
  ), '[]'::jsonb),
  'favorites', coalesce((
    select jsonb_agg(to_jsonb(favorite_state) order by favorite_state.user_id)
    from (
      select user_id, skill_id, created_at
      from public.favorites
      where user_id = '00000000-0000-4000-8000-000000000211'
    ) as favorite_state
  ), '[]'::jsonb),
  'submissions', coalesce((
    select jsonb_agg(to_jsonb(submission_state) order by submission_state.id)
    from (
      select * from public.submissions
      where id = '00000000-0000-4000-8000-000000000221'
    ) as submission_state
  ), '[]'::jsonb),
  'reports', coalesce((
    select jsonb_agg(to_jsonb(report_state) order by report_state.id)
    from (
      select * from public.skill_reports
      where id = '00000000-0000-4000-8000-000000000222'
    ) as report_state
  ), '[]'::jsonb),
  'functions', jsonb_build_object(
    'get_new_counts_by_category', pg_get_functiondef(
      'public.get_new_counts_by_category(timestamptz)'::regprocedure
    ),
    'get_category_counts', pg_get_functiondef(
      'public.get_category_counts()'::regprocedure
    ),
    'get_repo_groups', pg_get_functiondef(
      'public.get_repo_groups(text,integer,integer)'::regprocedure
    ),
    'delete_my_account', pg_get_functiondef(
      'public.delete_my_account()'::regprocedure
    ),
    'submit_skill_report', pg_get_functiondef(
      'public.submit_skill_report(uuid,text,text)'::regprocedure
    ),
    'apply_submission_decision', pg_get_functiondef(
      'public.apply_submission_decision(uuid,text,text,jsonb,jsonb)'::regprocedure
    ),
    'apply_skill_overrides', pg_get_functiondef(
      'public.apply_skill_overrides(text[],jsonb,jsonb,boolean)'::regprocedure
    ),
    'fill_skill_enrichment', pg_get_functiondef(
      'public.fill_skill_enrichment(uuid,timestamptz,text,text[],text[],text)'::regprocedure
    )
  )
)::text;
