-- =====================================================================
-- 019 — กติกาเวลากลับ
--   • ใบบัญชี/รายงาน/สรุปรายเดือน: "เวลากลับ" นับเฉพาะการสแกนตั้งแต่เวลาเลิกงาน (settings.work_end = 16:30) เป็นต้นไป
--     ถ้าสแกนซ้ำ นับครั้งแรก (เวลามา = สแกนแรกของวัน, เวลากลับ = สแกนแรกหลัง 16:30)
--     สแกนระหว่างวันก่อน 16:30 ที่ไม่ใช่ครั้งแรกจะไม่ถูกนับเป็นเวลากลับ → ขึ้น "ไม่ได้สแกนกลับ" จนกว่าจะสแกนหลัง 16:30
--     วันหยุด/ไม่ใช่วันทำการ ใช้แบบเดิม (รายการสุดท้ายของวัน)
--   • สรุปเวรนอกเวลา (Telegram): เวลากลับ = สแกนแรกตั้งแต่ settings.ot_end (18:30) เป็นต้นไป
-- รันใน Supabase SQL Editor ต่อจาก 018 (รันได้ซ้ำ)
-- =====================================================================

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
         (o.t_out at time zone 'Asia/Bangkok')::time,
         o.m_out,
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
           case when sc.ts is not null and o.t_out is null then 'ไม่ได้สแกนกลับ' end),
         st.id
  from staff st
  left join scans sc on sc.staff_id = st.id
  -- เวลากลับ: วันทำการ = สแกนแรกที่ตั้งแต่เวลาเลิกงาน (work_end) เป็นต้นไป (สแกนก่อนหน้านั้นไม่นับเป็นเวลากลับ,
  -- สแกนซ้ำนับครั้งแรก) และต้องเป็นคนละรายการกับเวลามา; วันหยุด/ไม่ใช่วันทำการ = รายการสุดท้ายของวันเหมือนเดิม
  left join lateral (
    select u.t as t_out, u.m as m_out
    from unnest(sc.ts, sc.ms) with ordinality as u(t, m, i)
    where u.i > 1
      and (not is_workday(p_day) or (u.t at time zone 'Asia/Bangkok')::time >= (select work_end from s))
    order by case when is_workday(p_day) then u.i else -u.i end
    limit 1
  ) o on true
  left join leave_records lv on lv.staff_id = st.id and lv.day = p_day
  where st.is_active and st.on_sheet
  order by st.sort_order, st.full_name;
$$;
grant execute on function daily_sheet(date) to authenticated;

create or replace function tg_msg_ot(p_day date) returns text
language sql stable security definer set search_path = public as $$
  with s as (select * from settings where id = 1),
  scans as (
    select l.staff_id, (l.log_time at time zone 'Asia/Bangkok')::time as t
    from attendance_logs l
    where (l.log_time at time zone 'Asia/Bangkok')::date = p_day
  ),
  duty as (
    select st.full_name, st.sort_order,
           min(sc.t) filter (where sc.t >= (select ot_start from s) - interval '30 minutes') as t_in,
           min(sc.t) filter (where sc.t >= (select ot_end from s)) as t_out
    from staff st join scans sc on sc.staff_id = st.id
    where st.is_active and st.on_sheet
    group by st.id, st.full_name, st.sort_order
    having count(*) filter (where sc.t >= (select ot_end from s)) > 0
  )
  select '🌙 <b>เวรนอกเวลาราชการ ' || to_char(p_day, 'DD/MM') || '/' || (extract(year from p_day)::int + 543) ||
         ' (' || to_char((select ot_start from s), 'HH24:MI') || '–' || to_char((select ot_end from s), 'HH24:MI') || ')</b>' || chr(10) ||
         coalesce(
           (select string_agg('• ' || tg_esc(full_name) || ' — ' ||
                    coalesce(to_char(t_in, 'HH24:MI'), '—') || '–' || to_char(t_out, 'HH24:MI'),
                    chr(10) order by sort_order) from duty),
           'ไม่มีการลงเวลานอกเวลาราชการ') ||
         chr(10) || '<i>(ข้อมูลจากเครื่องสแกนที่เข้าระบบแล้ว ณ เวลานี้)</i>';
$$;

revoke all on function tg_msg_ot(date) from public, anon, authenticated;

-- ตรวจผล: วันนี้ (ดูคอลัมน์ time_in / time_out)
select full_name, time_in, time_out, remark from daily_sheet((now() at time zone 'Asia/Bangkok')::date);
