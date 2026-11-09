-- =====================================================================
-- 015 — ไม่นับ "มาสาย" ในวันหยุด (เสาร์–อาทิตย์ / วันที่ไม่อยู่ใน settings.workdays / วันหยุดราชการในตาราง holidays)
-- รันใน Supabase SQL Editor ต่อจาก 014
-- =====================================================================

create or replace function is_workday(p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select extract(isodow from p_day)::int = any ((select workdays from settings where id = 1)::int[])
     and not exists (select 1 from holidays h where h.day = p_day);
$$;
grant execute on function is_workday(date) to authenticated;

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
         sc.ts is not null and is_workday(p_day) and (sc.ts[1] at time zone 'Asia/Bangkok')::time
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
