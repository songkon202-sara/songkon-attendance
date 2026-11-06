-- =====================================================================
-- 009 — สรุปรายเดือนต่อคน
-- วันทำการ = วันใน settings.workdays ที่ไม่ใช่วันหยุด (holidays) และไม่เกินวันนี้
-- =====================================================================

-- daily_sheet: เพิ่มคอลัมน์ staff_id ต่อท้าย (ใช้เชื่อมกับรายชื่อได้แม่นยำ)
drop function if exists daily_sheet(date);
create or replace function daily_sheet(p_day date)
returns table (
  sort_order int, full_name text, staff_type text,
  time_in time, method_in text, time_out time, method_out text,
  is_late boolean, status text, remark text, staff_id uuid
)
language sql stable security invoker set search_path = public as $$
  with s as (select * from settings where id = 1),
  scans as (
    select staff_id,
           array_agg(log_time order by log_time) as ts,
           array_agg(method   order by log_time) as ms,
           string_agg(distinct reason, ', ') filter (where in_area = false) as out_reason
    from attendance_logs
    where (log_time at time zone 'Asia/Bangkok')::date = p_day
    group by staff_id
  )
  select st.sort_order, st.full_name, st.staff_type,
         (sc.ts[1] at time zone 'Asia/Bangkok')::time,
         sc.ms[1],
         case when cardinality(sc.ts) > 1 then (sc.ts[cardinality(sc.ts)] at time zone 'Asia/Bangkok')::time end,
         case when cardinality(sc.ts) > 1 then sc.ms[cardinality(sc.ms)] end,
         sc.ts is not null and (sc.ts[1] at time zone 'Asia/Bangkok')::time
           > (select work_start + make_interval(mins => late_grace_min) from s),
         case
           when lv.kind = 'official'  then 'official'
           when sc.ts is not null     then 'present'
           else 'absent'                                  -- รวมลา
         end,
         concat_ws(' · ',
           case lv.kind when 'leave' then 'ลา' when 'official' then 'ไปราชการ' end,
           lv.note,
           case when sc.out_reason is not null then 'นอกพื้นที่ (' || sc.out_reason || ')' end,
           case when sc.ts is not null and cardinality(sc.ts) = 1 then 'ไม่ได้สแกนกลับ' end),
         st.id
  from staff st
  left join scans sc on sc.staff_id = st.id
  left join leave_records lv on lv.staff_id = st.id and lv.day = p_day
  where st.is_active and st.on_sheet
  order by st.sort_order, st.full_name;
$$;
grant execute on function daily_sheet(date) to authenticated;

create or replace function monthly_summary(p_month date)
returns table (
  staff_id uuid, sort_order int, full_name text, staff_position text, staff_type text,
  workdays int, present int, late int, official int, leave int, absent int,
  no_out int, away int, late_minutes int
)
language sql stable security invoker set search_path = public as $$
  with s as (select * from settings where id = 1),
  days as (
    select d::date as day
    from generate_series(date_trunc('month', p_month)::date,
                         least((date_trunc('month', p_month) + interval '1 month - 1 day')::date,
                               (now() at time zone 'Asia/Bangkok')::date), interval '1 day') d
    where extract(isodow from d)::int = any ((select workdays from s)::int[])
      and not exists (select 1 from holidays h where h.day = d::date)
  ),
  sheet as (
    select dd.day, ds.*
    from days dd cross join lateral daily_sheet(dd.day) ds
  )
  select st.id, st.sort_order, st.full_name, st.position, st.staff_type,
         (select count(*) from days)::int,
         count(*) filter (where sh.status = 'present')::int,
         count(*) filter (where sh.is_late)::int,
         count(*) filter (where sh.status = 'official')::int,
         count(*) filter (where sh.status = 'absent' and sh.remark like 'ลา%')::int,
         count(*) filter (where sh.status = 'absent' and coalesce(sh.remark, '') not like 'ลา%')::int,
         count(*) filter (where sh.status = 'present' and sh.time_out is null)::int,
         count(*) filter (where sh.remark like '%นอกพื้นที่%')::int,
         coalesce(sum(greatest(0, extract(epoch from (sh.time_in - (select work_start from s))) / 60)::int)
                  filter (where sh.is_late), 0)::int
  from staff st
  left join sheet sh on sh.staff_id = st.id
  where st.is_active and st.on_sheet
  group by st.id, st.sort_order, st.full_name, st.position, st.staff_type
  order by st.sort_order, st.full_name;
$$;
grant execute on function monthly_summary(date) to authenticated;

-- รายละเอียดรายวันของทั้งเดือน (ใช้ส่งออก Excel แผ่นที่ 2)
create or replace function monthly_detail(p_month date)
returns table (day date, full_name text, time_in time, method_in text, time_out time, method_out text,
               is_late boolean, status text, remark text)
language sql stable security invoker set search_path = public as $$
  select d::date, ds.full_name, ds.time_in, ds.method_in, ds.time_out, ds.method_out, ds.is_late, ds.status, ds.remark
  from generate_series(date_trunc('month', p_month)::date,
                       least((date_trunc('month', p_month) + interval '1 month - 1 day')::date,
                             (now() at time zone 'Asia/Bangkok')::date), interval '1 day') d
  cross join lateral daily_sheet(d::date) ds
  where extract(isodow from d)::int = any ((select workdays from settings where id = 1)::int[])
    and not exists (select 1 from holidays h where h.day = d::date)
  order by 1, ds.sort_order;
$$;
grant execute on function monthly_detail(date) to authenticated;
