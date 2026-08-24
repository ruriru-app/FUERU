-- Use the family's expected Japan calendar date for child job reports.
create or replace function public.report_job_from_child_service(
  p_family_id uuid,
  p_child_id uuid,
  p_job_id uuid,
  p_work_date date
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_job public.jobs%rowtype;
  v_report_id uuid;
  v_today date := (pg_catalog.now() at time zone 'Asia/Tokyo')::date;
begin
  if p_work_date is null or p_work_date > v_today then
    raise exception 'invalid_work_date';
  end if;

  select j.*
  into v_job
  from public.jobs j
  where j.id = p_job_id
    and j.family_id = p_family_id
    and j.child_id = p_child_id
    and j.enabled = true
    and j.archived_at is null
    and (j.start_date is null or p_work_date >= j.start_date)
    and (j.end_date is null or p_work_date <= j.end_date)
    and (
      j.frequency_type = 'daily'
      or extract(dow from p_work_date)::smallint = any(j.weekdays)
    );

  if not found then
    raise exception 'job_not_available';
  end if;

  insert into public.job_reports (
    family_id,
    child_id,
    job_id,
    work_date,
    status,
    reward_amount,
    job_snapshot,
    reported_at
  ) values (
    p_family_id,
    p_child_id,
    v_job.id,
    p_work_date,
    'waiting',
    v_job.reward_amount,
    pg_catalog.jsonb_build_object(
      'jobId', v_job.id,
      'name', v_job.name,
      'reward', v_job.reward_amount,
      'frequency', case when v_job.frequency_type = 'daily' then 'daily' else 'weekdays' end,
      'days', pg_catalog.to_jsonb(v_job.weekdays)
    ),
    pg_catalog.now()
  )
  on conflict (child_id, job_id, work_date)
  do update set
    status = 'waiting',
    reward_amount = excluded.reward_amount,
    job_snapshot = excluded.job_snapshot,
    reported_at = pg_catalog.now(),
    reviewed_at = null,
    reviewed_by = null
  where public.job_reports.status <> 'done'
  returning id into v_report_id;

  if v_report_id is null then
    raise exception 'report_already_reviewed';
  end if;

  return v_report_id;
end;
$function$;

