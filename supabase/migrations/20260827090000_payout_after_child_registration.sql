-- Do not create an allowance transaction for a payday before the child joined FUERU.
create or replace function public.process_child_payout(
  p_child_id uuid,
  p_as_of_date date default current_date,
  p_trigger text default 'manual'
)
returns table(
  allowance_amount integer,
  reward_amount integer,
  total_amount integer,
  allowance_transaction_id uuid,
  reward_transaction_id uuid
)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_family_id uuid;
  v_child_registered_on date;
  v_allowance integer;
  v_pay_type text;
  v_pay_day integer;
  v_payout_mode text;
  v_month_start date;
  v_month_end date;
  v_allowance_due date;
  v_pending_ids uuid[];
  v_pending_count integer;
  v_reward_total bigint;
  v_reward_items jsonb;
  v_batch_key text;
begin
  if p_as_of_date is null then
    raise exception 'payout date is required';
  end if;
  if p_trigger not in ('manual', 'auto') then
    raise exception 'invalid payout trigger';
  end if;

  select
    c.family_id,
    (c.created_at at time zone 'Asia/Tokyo')::date,
    s.allowance,
    s.pay_type,
    s.pay_day,
    s.payout_mode
  into
    v_family_id,
    v_child_registered_on,
    v_allowance,
    v_pay_type,
    v_pay_day,
    v_payout_mode
  from public.children c
  join public.child_settings s
    on s.child_id = c.id
   and s.family_id = c.family_id
  where c.id = p_child_id
    and c.archived_at is null
  for update of c, s;

  if not found then
    raise exception 'child not found';
  end if;
  if not private.is_guardian_of(v_family_id) then
    raise exception 'not authorized for this family';
  end if;
  if p_trigger = 'auto' and v_payout_mode <> 'auto' then
    raise exception 'automatic payout is disabled for this child';
  end if;

  allowance_amount := 0;
  reward_amount := 0;
  total_amount := 0;
  allowance_transaction_id := null;
  reward_transaction_id := null;

  v_month_start := pg_catalog.date_trunc('month', p_as_of_date::timestamp)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  if v_pay_type = 'monthEnd' then
    v_allowance_due := v_month_end;
  else
    v_allowance_due := pg_catalog.make_date(
      extract(year from v_month_start)::integer,
      extract(month from v_month_start)::integer,
      least(coalesce(v_pay_day, 25), extract(day from v_month_end)::integer)
    );
  end if;

  if v_allowance_due <= p_as_of_date
     and v_allowance_due >= v_child_registered_on
     and v_allowance > 0 then
    insert into public.passbook_transactions (
      family_id, child_id, transaction_type, amount, transaction_date,
      reason, items, source_type, source_key, created_by
    ) values (
      v_family_id, p_child_id, 'allowance', v_allowance, v_allowance_due,
      '定額お小遣い',
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('name', '定額お小遣い', 'amount', v_allowance)
      ),
      'allowance_due', v_allowance_due::text, auth.uid()
    )
    on conflict do nothing
    returning id into allowance_transaction_id;

    if allowance_transaction_id is not null then
      allowance_amount := v_allowance;
    end if;
  end if;

  select
    pg_catalog.array_agg(q.id order by q.id),
    count(*)::integer,
    coalesce(pg_catalog.sum(q.amount), 0),
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'name', q.job_name,
          'amount', q.amount,
          'workDate', q.work_date
        ) order by q.work_date, q.id
      ),
      '[]'::jsonb
    )
  into v_pending_ids, v_pending_count, v_reward_total, v_reward_items
  from (
    select pr.id, pr.amount, pr.job_name, pr.work_date
    from public.pending_rewards pr
    where pr.family_id = v_family_id
      and pr.child_id = p_child_id
      and pr.status = 'pending'
      and pr.due_date <= p_as_of_date
    order by pr.id
    for update
  ) q;

  if v_pending_count > 0 then
    v_batch_key := 'pending:' || pg_catalog.md5(pg_catalog.array_to_string(v_pending_ids, ','));
    if v_reward_total > 0 then
      insert into public.passbook_transactions (
        family_id, child_id, transaction_type, amount, transaction_date,
        reason, items, source_type, source_key, created_by
      ) values (
        v_family_id, p_child_id, 'job', v_reward_total::integer, p_as_of_date,
        'お仕事報酬', v_reward_items, 'pending_reward_batch', v_batch_key, auth.uid()
      )
      on conflict do nothing
      returning id into reward_transaction_id;

      if reward_transaction_id is null then
        select pt.id
        into reward_transaction_id
        from public.passbook_transactions pt
        where pt.family_id = v_family_id
          and pt.child_id = p_child_id
          and pt.source_type = 'pending_reward_batch'
          and pt.source_key = v_batch_key;
      end if;
      reward_amount := v_reward_total::integer;
    end if;

    update public.pending_rewards pr
    set status = 'paid',
        paid_transaction_id = reward_transaction_id,
        paid_at = pg_catalog.now()
    where pr.id = any(v_pending_ids)
      and pr.status = 'pending';
  end if;

  total_amount := allowance_amount + reward_amount;
  return next;
end;
$function$;
