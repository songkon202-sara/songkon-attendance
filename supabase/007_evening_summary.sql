-- 007 — สรุปเวรนอกเวลาราชการ (16:30–18:30) ส่ง Telegram 18:45
-- รันใน Supabase SQL Editor ต่อจาก 006
alter table settings add column if not exists ot_start time default '16:30';      -- เริ่มนอกเวลาราชการ
alter table settings add column if not exists ot_end   time default '18:30';      -- เลิกนอกเวลาราชการ
alter table settings add column if not exists summary_time2 time default '18:45'; -- เวลาส่งสรุปเวรนอกเวลา (ว่าง = ไม่ส่ง)

-- รายชื่อคนที่อยู่เวรนอกเวลา: มีสแกนตั้งแต่ 1 ชั่วโมงก่อนเลิกนอกเวลา (ค่าเริ่มต้น 17:30) เป็นต้นไป
-- เวลาเริ่ม = สแกนแรกตั้งแต่ 30 นาทีก่อนเริ่มนอกเวลา, เวลาเลิก = สแกนสุดท้ายของวัน
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
           max(sc.t) as t_out
    from staff st join scans sc on sc.staff_id = st.id
    where st.is_active and st.on_sheet
    group by st.id, st.full_name, st.sort_order
    having max(sc.t) >= (select ot_end from s) - interval '60 minutes'
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
alter table notify_log drop constraint if exists notify_log_kind_check;
alter table notify_log add constraint notify_log_kind_check check (kind in ('late', 'summary', 'summary2'));

create or replace function tg_tick() returns text
language plpgsql security definer set search_path = public as $$
declare
  s      settings;
  nowbk  timestamp := now() at time zone 'Asia/Bangkok';
  d      date := nowbk::date;
  t      time := nowbk::time;
  since  timestamptz;
  upto   timestamptz := now();
  msg    text;
  did    text := '';
begin
  select * into s from settings where id = 1;
  if not s.telegram_notify then return 'ปิดการแจ้งเตือน'; end if;
  if not (extract(isodow from d)::int = any (s.workdays)) or exists (select 1 from holidays where day = d) then
    return 'ไม่ใช่วันทำงาน';
  end if;

  -- 1) ลงเวลาใหม่ (07:30–17:30)
  if t between time '07:30' and time '17:30' then
    select last_scan_created into since from notify_state where id = 1;
    msg := tg_msg_new_scans(since, upto);
    update notify_state set last_scan_created = upto where id = 1;
    if msg is not null then perform tg_send(msg); did := did || 'ลงเวลาใหม่ '; end if;
  else
    update notify_state set last_scan_created = upto where id = 1;
  end if;

  -- 2) มาสาย / ยังไม่ลงเวลา — ครั้งเดียวต่อวัน
  if t >= s.work_start + make_interval(mins => s.late_grace_min + 15)
     and t < s.work_end
     and not exists (select 1 from notify_log where day = d and kind = 'late') then
    perform tg_send(tg_msg_late(d));
    insert into notify_log (day, kind) values (d, 'late');
    did := did || 'มาสาย ';
  end if;

  -- 3) สรุปรายวัน — หลังเลิกงาน 15 นาที (ครั้งเดียวต่อวัน)
  if t >= s.work_end + interval '15 minutes'
     and not exists (select 1 from notify_log where day = d and kind = 'summary') then
    perform tg_send(tg_msg_summary(d));
    insert into notify_log (day, kind) values (d, 'summary');
    did := did || 'สรุปรายวัน ';
  end if;

  -- 4) สรุปเวรนอกเวลาราชการ (settings.summary_time2 ค่าเริ่มต้น 18:45; ว่าง = ไม่ส่ง)
  if s.summary_time2 is not null and t >= s.summary_time2
     and not exists (select 1 from notify_log where day = d and kind = 'summary2') then
    perform tg_send(tg_msg_ot(d));
    insert into notify_log (day, kind) values (d, 'summary2');
    did := did || 'เวรนอกเวลา ';
  end if;

  return coalesce(nullif(trim(did), ''), 'ไม่มีอะไรต้องส่ง');
end $$;

revoke all on function tg_tick(), tg_msg_ot(date) from public, anon, authenticated;
