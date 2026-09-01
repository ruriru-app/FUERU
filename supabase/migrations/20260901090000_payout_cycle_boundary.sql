-- Keep work rewards in the correct closed payout cycle.
-- A reward is scheduled after the work period closes. If that payout batch has
-- already been processed, the reward rolls forward to the next payout date.

create or replace function private.reward_due_date(
  p_child_id uuid,
  p_approval_date date
)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v_schedule text;
  v_pay_day integer;
  v_close_type text;
  v_close_day integer;
  v_month_start date;
  v_month_end date;
  v_close_date date;
  v_due date;
  v_guard integer := 0;
begin
  if p_approval_date is null then
    raise exception 'work date is required';
  end if;

  select
    case when s.reward_pay_schedule = 'allowance' then s.pay_type else s.reward_pay_schedule end,
    case when s.reward_pay_schedule = 'allowance' then s.pay_day else s.reward_pay_day end,
    coalesce(s.close_type, 'monthEnd'),
    coalesce(s.close_day, 31)
  into v_schedule, v_pay_day, v_close_type, v_close_day
  from public.child_settings s
  where s.child_id = p_child_id;

  if not found then
    raise exception 'child settings not found';
  end if;

  v_month_start := pg_catalog.date_trunc('month', p_approval_date::timestamp)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;

  if v_close_type = 'monthEnd' then
    v_close_date := v_month_end;
  else
    v_close_date := pg_catalog.make_date(
      extract(year from v_month_start)::integer,
      extract(month from v_month_start)::integer,
      least(greatest(v_close_day, 1), extract(day from v_month_end)::integer)
    );
    if p_approval_date > v_close_date then
      v_month_start := (v_month_start + interval '1 month')::date;
      v_month_end := (v_month_start + interval '1 month - 1 day')::date;
      v_close_date := pg_catalog.make_date(
        extract(year from v_month_start)::integer,
        extract(month from v_month_start)::integer,
        least(greatest(v_close_day, 1), extract(day from v_month_end)::integer)
      );
    end if;
  end if;

  v_month_start := pg_catalog.date_trunc('month', v_close_date::timestamp)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  if v_schedule = 'monthEnd' then
    v_due := v_month_end;
  else
    v_due := pg_catalog.make_date(
      extract(year from v_month_start)::integer,
      extract(month from v_month_start)::integer,
      least(coalesce(v_pay_day, 25), extract(day from v_month_end)::integer)
    );
  end if;

  if v_due <= v_close_date then
    v_month_start := (v_month_start + interval '1 month')::date;
    v_month_end := (v_month_start + interval '1 month - 1 day')::date;
    if v_schedule = 'monthEnd' then
      v_due := v_month_end;
    else
      v_due := pg_catalog.make_date(
        extract(year from v_month_start)::integer,
        extract(month from v_month_start)::integer,
        least(coalesce(v_pay_day, 25), extract(day from v_month_end)::integer)
      );
    end if;
  end if;

  while exists (
    select 1
    from public.passbook_transactions t
    where t.child_id = p_child_id
      and t.source_type = 'pending_reward_batch'
      and t.transaction_date = v_due
  ) loop
    v_guard := v_guard + 1;
    exit when v_guard > 24;
    v_month_start := (pg_catalog.date_trunc('month', v_due::timestamp) + interval '1 month')::date;
    v_month_end := (v_month_start + interval '1 month - 1 day')::date;
    if v_schedule = 'monthEnd' then
      v_due := v_month_end;
    else
      v_due := pg_catalog.make_date(
        extract(year from v_month_start)::integer,
        extract(month from v_month_start)::integer,
        least(coalesce(v_pay_day, 25), extract(day from v_month_end)::integer)
      );
    end if;
  end loop;

  return v_due;
end;
$$;

revoke all on function private.reward_due_date(uuid, date) from public;
revoke all on function private.reward_due_date(uuid, date) from anon;
revoke all on function private.reward_due_date(uuid, date) from authenticated;

create or replace function public.review_job_report(
  p_report_id uuid,
  p_decision text
)
returns public.job_reports
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_report public.job_reports;
  v_reward_timing text;
  v_due_date date;
begin
  if p_decision not in ('done', 'missed', 'cancelled') then
    raise exception 'invalid decision';
  end if;

  select * into v_report
  from public.job_reports
  where id = p_report_id
  for update;

  if not found then raise exception 'report not found'; end if;
  if not private.is_guardian_of(v_report.family_id) then raise exception 'not authorized for this family'; end if;
  if v_report.status = p_decision then return v_report; end if;
  if v_report.status <> 'waiting' then raise exception 'report already reviewed'; end if;

  update public.job_reports
  set status = p_decision,
      reviewed_at = pg_catalog.now(),
      reviewed_by = auth.uid()
  where id = p_report_id
  returning * into v_report;

  if p_decision <> 'done' then return v_report; end if;

  select s.reward_timing into v_reward_timing
  from public.child_settings s
  where s.child_id = v_report.child_id and s.family_id = v_report.family_id;

  if not found then raise exception 'child settings not found'; end if;

  if v_reward_timing = 'immediate' then
    if v_report.reward_amount > 0 then
      insert into public.passbook_transactions (
        family_id, child_id, transaction_type, amount, transaction_date,
        reason, items, source_type, source_key, created_by
      ) values (
        v_report.family_id, v_report.child_id, 'job', v_report.reward_amount,
        v_report.work_date, coalesce(v_report.job_snapshot->>'name', 'お仕事報酬'),
        pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'name', coalesce(v_report.job_snapshot->>'name', 'お仕事報酬'),
          'amount', v_report.reward_amount, 'workDate', v_report.work_date
        )),
        'job_report', v_report.id::text, auth.uid()
      ) on conflict do nothing;
    end if;
  else
    v_due_date := private.reward_due_date(v_report.child_id, v_report.work_date);
    insert into public.pending_rewards (
      family_id, child_id, job_report_id, amount, job_name, work_date, due_date, status
    ) values (
      v_report.family_id, v_report.child_id, v_report.id, v_report.reward_amount,
      coalesce(v_report.job_snapshot->>'name', 'お仕事報酬'), v_report.work_date,
      v_due_date, 'pending'
    ) on conflict (job_report_id) do nothing;
  end if;

  return v_report;
end;
$$;

revoke all on function public.review_job_report(uuid, text) from public;
revoke all on function public.review_job_report(uuid, text) from anon;
grant execute on function public.review_job_report(uuid, text) to authenticated;

-- Repair only unpaid rewards; paid transactions and balances are untouched.
update public.pending_rewards pr
set due_date = private.reward_due_date(pr.child_id, pr.work_date)
where pr.status = 'pending'
  and pr.due_date is distinct from private.reward_due_date(pr.child_id, pr.work_date);
