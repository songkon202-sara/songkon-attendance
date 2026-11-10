-- =====================================================================
-- 018 — กันเหตุผิดปกติ (ความเสถียร + ความปลอดภัย)
--   1) ตรวจว่าตัวดึงข้อมูลบนคอมฯ ยัง "มีชีวิต" ไหม (heartbeat) โดยไม่ต้องแก้โปรแกรมบนคอม
--   2) Telegram เตือนเมื่อคอมเงียบเกิน 20 นาทีช่วง 07:30–17:00 ของวันทำการ (วันละครั้ง) + แจ้งเมื่อกลับมา
--   3) กันปี พ.ศ. หลุดเข้าฐานข้อมูล (แปลงเป็น ค.ศ. อัตโนมัติ)
--   4) กันลงเวลามือถือซ้ำภายใน 2 นาที
-- รันใน Supabase SQL Editor ต่อจาก 017 (รันได้ซ้ำ)
-- =====================================================================

-- 1) heartbeat: ตัวดึงข้อมูลเรียก hip_last_scan_id ทุกรอบ (ทุก 1 นาที) อยู่แล้ว
alter table device_sync add column if not exists last_seen_at timestamptz;

create or replace function hip_last_scan_id(p_secret text)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from app_secrets
                 where name = 'hip_agent'
                   and secret_hash = encode(digest(p_secret, 'sha256'), 'hex')) then
    raise exception 'unauthorized';
  end if;
  update device_sync set last_seen_at = now() where id = 1;
  return (select last_scan_id from device_sync where id = 1);
end $$;

-- 2) ชนิดข้อความแจ้งเตือนเพิ่ม
alter table notify_log drop constraint if exists notify_log_kind_check;
alter table notify_log add constraint notify_log_kind_check
  check (kind in ('late','summary','summary2','stale','stale_ok'));

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
  seen   timestamptz;
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

  -- 5) เฝ้าระวังตัวดึงข้อมูลบนคอมฯ: เงียบเกิน 20 นาทีช่วงเวลาทำการ → เตือน (วันละครั้ง) และแจ้งเมื่อกลับมาปกติ
  select last_seen_at into seen from device_sync where id = 1;
  if seen is not null then
    if t between time '07:30' and time '17:00' and now() - seen > interval '20 minutes'
       and not exists (select 1 from notify_log where day = d and kind = 'stale') then
      perform tg_send('⚠️ ระบบลงเวลา: คอมที่ต่อเครื่องสแกนไม่ส่งข้อมูลมาแล้ว ' || round(extract(epoch from (now() - seen)) / 60) || ' นาที'
        || E'\nตรวจว่าคอมเปิดอยู่ มีอินเทอร์เน็ต และโปรแกรม HIP Time เปิดอยู่ (Real Time เริ่มทำงาน)'
        || E'\nข้อมูลในเครื่องสแกนไม่หาย จะเข้าระบบเมื่อกลับมาปกติ');
      insert into notify_log (day, kind) values (d, 'stale');
      did := did || 'ระบบเงียบ ';
    elsif exists (select 1 from notify_log where day = d and kind = 'stale')
       and not exists (select 1 from notify_log where day = d and kind = 'stale_ok')
       and now() - seen < interval '5 minutes' then
      perform tg_send('✅ ระบบลงเวลา: คอมกลับมาส่งข้อมูลตามปกติแล้ว');
      insert into notify_log (day, kind) values (d, 'stale_ok');
      did := did || 'กลับมาปกติ ';
    end if;
  end if;

  return coalesce(nullif(trim(did), ''), 'ไม่มีอะไรต้องส่ง');
end $$;

revoke all on function tg_tick() from public, anon, authenticated;

-- 3) กันปี พ.ศ.
create or replace function fix_buddhist_year() returns trigger
language plpgsql set search_path = public as $$
begin
  if extract(year from (new.log_time at time zone 'Asia/Bangkok')) > 2400 then
    new.log_time := ((new.log_time at time zone 'Asia/Bangkok') - interval '543 years') at time zone 'Asia/Bangkok';
  end if;
  return new;
end $$;

drop trigger if exists fix_year_logs on attendance_logs;
create trigger fix_year_logs before insert or update of log_time on attendance_logs
  for each row execute function fix_buddhist_year();
drop trigger if exists fix_year_unmatched on hip_unmatched;
create trigger fix_year_unmatched before insert or update of log_time on hip_unmatched
  for each row execute function fix_buddhist_year();

-- 4) ลงเวลามือถือ: ห้ามซ้ำภายใน 2 นาที
create or replace function mobile_check_in(
  p_direction   text,
  p_lat         float8,
  p_lng         float8,
  p_reason      text,
  p_selfie_path text,
  p_descriptor  jsonb,
  p_accuracy    float8 default null,
  p_liveness    text default null
) returns attendance_logs
language plpgsql security definer set search_path = public as $$
declare
  s settings; me uuid := my_staff_id(); d int; inside boolean; rec attendance_logs;
  v float8[]; dist float8;
begin
  if me is null then raise exception 'ไม่พบเจ้าหน้าที่ของบัญชีนี้'; end if;
  if p_direction not in ('in','out') then raise exception 'direction ไม่ถูกต้อง'; end if;
  select * into s from settings where id = 1;
  -- กันกดซ้ำรัว ๆ / ส่งซ้ำ: ห้ามลงเวลามือถือซ้ำภายใน 2 นาที
  if exists (select 1 from attendance_logs where staff_id = me and method = 'mobile' and log_time > now() - interval '2 minutes') then
    raise exception 'เพิ่งลงเวลาไป รออีก 2 นาทีแล้วลองใหม่';
  end if;
  if s.require_gps and (p_lat is null or p_lng is null) then raise exception 'ต้องเปิด GPS'; end if;
  if coalesce(p_selfie_path, '') not like me::text || '/%' then raise exception 'ต้องถ่ายรูปยืนยัน'; end if;

  if not exists (select 1 from face_templates where staff_id = me and approved_at is not null) then
    raise exception 'ใบหน้ายังไม่ได้รับการอนุมัติจากผู้ดูแลระบบ';
  end if;
  if jsonb_typeof(p_descriptor) <> 'array' or jsonb_array_length(p_descriptor) <> 128 then
    raise exception 'ข้อมูลใบหน้าไม่ถูกต้อง';
  end if;
  v := array(select (x)::float8 from jsonb_array_elements_text(p_descriptor) x);
  dist := face_distance(me, v);
  if dist is null or dist > s.face_threshold then
    raise exception 'ใบหน้าไม่ตรงกับที่ลงทะเบียนไว้ (ค่า %) ลองอีกครั้ง', round(coalesce(dist, 9)::numeric, 2);
  end if;

  d := distance_m(s.site_lat, s.site_lng, p_lat, p_lng);
  inside := d <= s.radius_m;
  if not inside and coalesce(trim(p_reason), '') = '' then
    raise exception 'ลงเวลานอกพื้นที่ ต้องระบุเหตุผล';
  end if;

  insert into attendance_logs
    (staff_id, log_time, method, direction, lat, lng, distance_m, in_area,
     reason, selfie_path, face_score, gps_accuracy_m, liveness)
  values
    (me, now(), 'mobile', p_direction, p_lat, p_lng, d, inside,
     case when inside then null else p_reason end, p_selfie_path, round(dist::numeric, 3),
     round(p_accuracy)::int, left(p_liveness, 40))
  returning * into rec;
  return rec;
end $$;

-- ตรวจผล (ควรเห็น last_seen_at ขยับภายใน 1–2 นาที)
select last_seen_at, last_sync_at, last_scan_id from device_sync where id = 1;
