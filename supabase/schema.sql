-- =====================================================================
-- ระบบลงเวลาปฏิบัติราชการ รพ.สต.สองคอน — โครงฐานข้อมูล (Supabase / PostgreSQL)
-- ฉบับที่ 3 — รันใน Supabase SQL Editor ของโปรเจกต์ songkon-attendance (ครั้งเดียว บนโปรเจกต์ใหม่)
-- เปลี่ยนจากฉบับที่ 2:
--   * รับข้อมูลจาก HIP Time (SQL Server ตาราง Transcantime) ผ่านฟังก์ชัน hip_ingest()
--     ใช้รหัสลับเฉพาะตัวส่งข้อมูล ไม่ต้องฝาก service key ไว้บนเครื่อง
--   * attendance_logs เพิ่ม hip_scan_id (กันซ้ำ) + เก็บ verifymode ดิบ; เพิ่มช่องทาง "บัตร"
--   * ตารางรายการที่จับคู่รหัสเจ้าหน้าที่ไม่ได้ (hip_unmatched)
--   * กำหนดสิทธิ์ (GRANT) เอง เพราะปิด "Automatically expose new tables"
-- เปลี่ยนจากฉบับที่ 1:
--   * ช่องทางลงเวลา 4 แบบ: ใบหน้า / ลายนิ้วมือ / รหัส (จากเครื่อง HIP) + มือถือ
--   * ตัดระบบอนุมัติ: สแกนนอกพื้นที่ = ลงเวลาปกติ + หมายเหตุ "นอกพื้นที่"
--   * มาสาย = หลังเวลาเข้างาน 15 นาที, แจ้งเตือน Telegram + สรุปรายวัน 16:30
--   * ดึงข้อมูลจากเครื่อง HIP อัตโนมัติผ่าน LAN (โปรแกรมบนคอมฯ ที่ รพ.สต.)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) เจ้าหน้าที่
-- ---------------------------------------------------------------------
create table staff (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  hip_user_id   text unique,              -- รหัสผู้ใช้บนเครื่อง HIP (ใช้จับคู่ข้อมูลจากเครื่อง)
  full_name     text not null,
  position      text,
  staff_type    text not null default 'civil'
                check (staff_type in ('civil','seconded','other')),
  -- civil=ข้าราชการ, seconded=ยืมตัวมาช่วยราชการ, other=ลูกจ้าง/พนักงาน
  role          text not null default 'staff' check (role in ('staff','admin')),
  is_active     boolean not null default true,
  sort_order    int not null default 0,   -- ลำดับในใบบัญชีลงเวลา
  created_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2) ข้อมูลใบหน้าสำหรับลงเวลาผ่านมือถือ (เก็บเป็นเวกเตอร์ตัวเลข ไม่เก็บรูปต้นฉบับ)
-- ---------------------------------------------------------------------
create table face_templates (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references staff(id) on delete cascade,
  descriptor  float8[] not null,
  consent_at  timestamptz not null,       -- เวลาที่ยินยอม (PDPA)
  created_at  timestamptz not null default now(),
  check (array_length(descriptor, 1) = 128)
);

-- ---------------------------------------------------------------------
-- 3) ตั้งค่าระบบ (แถวเดียว)
-- ---------------------------------------------------------------------
create table settings (
  id               int primary key default 1 check (id = 1),
  site_name        text not null default 'โรงพยาบาลส่งเสริมสุขภาพตำบลสองคอน',
  district         text not null default 'โพธิ์ไทร',
  province         text not null default 'อุบลราชธานี',
  site_lat         float8 not null default 15.828287,
  site_lng         float8 not null default 105.380604,
  radius_m         int not null default 100,
  work_start       time not null default '08:30',
  late_grace_min   int  not null default 15,       -- มาหลังเวลาเข้างานเกินกี่นาทีนับว่าสาย
  work_end         time not null default '16:30',
  summary_time     time not null default '16:30',  -- เวลาส่งสรุปรายวันเข้า Telegram
  workdays         int[] not null default '{1,2,3,4,5}', -- 1=จันทร์ ... 7=อาทิตย์
  face_threshold   float8 not null default 0.5,
  require_selfie   boolean not null default true,
  require_gps      boolean not null default true,
  vacancies        int not null default 0,         -- อัตราว่าง (ท้ายใบบัญชีลงเวลา)
  telegram_notify  boolean not null default true,
  telegram_chat_id text,                           -- กลุ่ม/หัวข้อปลายทาง (bot token เก็บใน secrets ไม่เก็บในตาราง)
  telegram_topic_id text,
  sheets_export    boolean not null default false
);
insert into settings default values on conflict do nothing;

-- ---------------------------------------------------------------------
-- 4) วันหยุด และ ลา/ไปราชการ (บันทึกโดยแอดมิน)
-- ---------------------------------------------------------------------
create table holidays (
  day   date primary key,
  name  text not null
);

create table leave_records (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references staff(id) on delete cascade,
  day         date not null,
  kind        text not null check (kind in ('leave','official','other')),
  -- leave=ลา (นับใน "ไม่มา"), official=ไปราชการ, other=อื่น ๆ
  note        text,
  created_by  uuid references staff(id),
  created_at  timestamptz not null default now(),
  unique (staff_id, day)
);

-- ---------------------------------------------------------------------
-- 5) รายการสแกนทั้งหมด (เครื่อง HIP + มือถือ)
-- ---------------------------------------------------------------------
create table attendance_logs (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid not null references staff(id) on delete cascade,
  log_time      timestamptz not null,
  method        text not null check (method in ('face','finger','password','card','other','mobile')),
  -- face=ใบหน้า, finger=ลายนิ้วมือ, password=รหัส, card=บัตร, other=อื่น ๆ (จากเครื่อง HIP), mobile=มือถือ
  hip_scan_id   bigint unique,    -- Transcantime.id ใน HIP Time (กันซ้ำ / ดึงต่อจากจุดเดิม)
  hip_verify    text,             -- verifymode / verifymodestr ดิบ (ไว้ตรวจการแปลงช่องทาง)
  direction     text check (direction in ('in','out')),  -- เครื่อง HIP อาจไม่ระบุ
  -- เฉพาะมือถือ
  lat           float8,
  lng           float8,
  distance_m    int,
  in_area       boolean,
  reason        text,             -- เหตุผลเมื่อลงเวลานอกพื้นที่ (ไปราชการ/เยี่ยมบ้าน/อบรม/อื่น ๆ)
  selfie_path   text,
  face_score    float8,
  created_at    timestamptz not null default now(),
  unique (staff_id, log_time, method)    -- กันข้อมูลซ้ำเมื่อดึงจากเครื่องซ้ำ
);
create index on attendance_logs (staff_id, log_time);

-- ---------------------------------------------------------------------
-- 6) สถานะการดึงข้อมูลจากเครื่อง HIP (โปรแกรมบนคอมฯ ที่ รพ.สต. ส่งทุก 5 นาที)
-- ---------------------------------------------------------------------
create table device_sync (
  id            int primary key default 1 check (id = 1),
  last_sync_at  timestamptz,
  last_scan_id  bigint not null default 0,  -- Transcantime.id ล่าสุดที่รับแล้ว
  last_log_time timestamptz,
  last_error    text
);
insert into device_sync default values on conflict do nothing;

-- รายการจากเครื่องที่ยังจับคู่กับเจ้าหน้าที่ไม่ได้ (ยังไม่ได้ใส่รหัส HIP ในรายชื่อ)
create table hip_unmatched (
  hip_scan_id   bigint primary key,
  enroll_number text not null,
  log_time      timestamptz not null,
  hip_verify    text,
  received_at   timestamptz not null default now()
);

-- รหัสลับของตัวส่งข้อมูล (เก็บเป็นค่า hash; ไม่มี policy = ผู้ใช้ทั่วไปอ่านไม่ได้)
create table app_secrets (
  name        text primary key,
  secret_hash text not null
);

-- กันแจ้งเตือนซ้ำ
create table notify_log (
  day   date not null,
  kind  text not null check (kind in ('late','summary')),
  sent_at timestamptz not null default now(),
  primary key (day, kind)
);

-- ---------------------------------------------------------------------
-- 7) ฟังก์ชันช่วย
-- ---------------------------------------------------------------------
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff
                 where auth_user_id = auth.uid() and role = 'admin' and is_active);
$$;

create or replace function my_staff_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from staff where auth_user_id = auth.uid();
$$;

create or replace function distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns int language sql immutable as $$
  select round(2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )))::int;
$$;

-- ลงเวลาผ่านมือถือ: เซิร์ฟเวอร์คำนวณระยะเอง; นอกพื้นที่ต้องมีเหตุผล แต่ไม่ต้องรออนุมัติ
create or replace function mobile_check_in(
  p_direction   text,
  p_lat         float8,
  p_lng         float8,
  p_reason      text default null,
  p_selfie_path text default null,
  p_face_score  float8 default null
) returns attendance_logs
language plpgsql security definer set search_path = public as $$
declare
  s      settings;
  me     uuid := my_staff_id();
  d      int;
  inside boolean;
  rec    attendance_logs;
begin
  if me is null then raise exception 'ไม่พบเจ้าหน้าที่ของบัญชีนี้'; end if;
  if p_direction not in ('in','out') then raise exception 'direction ไม่ถูกต้อง'; end if;
  select * into s from settings where id = 1;
  if s.require_gps and (p_lat is null or p_lng is null) then raise exception 'ต้องเปิด GPS'; end if;
  if s.require_selfie and p_selfie_path is null then raise exception 'ต้องถ่ายรูปยืนยัน'; end if;

  d := distance_m(s.site_lat, s.site_lng, p_lat, p_lng);
  inside := d <= s.radius_m;
  if not inside and coalesce(trim(p_reason), '') = '' then
    raise exception 'ลงเวลานอกพื้นที่ ต้องระบุเหตุผล';
  end if;

  insert into attendance_logs
    (staff_id, log_time, method, direction, lat, lng, distance_m, in_area,
     reason, selfie_path, face_score)
  values
    (me, now(), 'mobile', p_direction, p_lat, p_lng, d, inside,
     case when inside then null else p_reason end, p_selfie_path, p_face_score)
  returning * into rec;
  return rec;
end $$;

-- แปลงวิธีสแกนของ HIP เป็นช่องทาง (ปรับได้หลังดูข้อมูลจริง)
create or replace function hip_method(p_mode int, p_str text)
returns text language sql immutable as $$
  select case
    when p_str ilike '%face%'   or p_str like '%ใบหน้า%' then 'face'
    when p_str ilike '%finger%' or p_str ilike '%fp%' or p_str like '%นิ้ว%' then 'finger'
    when p_str ilike '%pass%'   or p_str ilike '%pwd%' or p_str like '%รหัส%' then 'password'
    when p_str ilike '%card%'   or p_str like '%บัตร%' then 'card'
    else 'other'
  end;
$$;

-- รับข้อมูลจากตัวส่งข้อมูลบนเครื่อง HIP Time
-- p_rows = [{"id":123,"enroll":"5","mode":1,"mode_str":"Finger","time":"2026-11-06T08:02:11+07:00"}, ...]
create or replace function hip_ingest(p_secret text, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  r        jsonb;
  sid      uuid;
  n_new    int := 0;
  n_unm    int := 0;
  max_id   bigint := 0;
  max_time timestamptz;
begin
  if not exists (select 1 from app_secrets
                 where name = 'hip_agent'
                   and secret_hash = encode(digest(p_secret, 'sha256'), 'hex')) then
    raise exception 'unauthorized';
  end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'too many rows'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    max_id   := greatest(max_id, (r->>'id')::bigint);
    max_time := greatest(max_time, (r->>'time')::timestamptz);
    select id into sid from staff where hip_user_id = r->>'enroll' and is_active;
    if sid is null then
      insert into hip_unmatched (hip_scan_id, enroll_number, log_time, hip_verify)
      values ((r->>'id')::bigint, r->>'enroll', (r->>'time')::timestamptz,
              concat_ws(':', r->>'mode', r->>'mode_str'))
      on conflict do nothing;
      n_unm := n_unm + 1;
    else
      insert into attendance_logs (staff_id, log_time, method, hip_scan_id, hip_verify)
      values (sid, (r->>'time')::timestamptz,
              hip_method((r->>'mode')::int, r->>'mode_str'),
              (r->>'id')::bigint, concat_ws(':', r->>'mode', r->>'mode_str'))
      on conflict do nothing;
      if found then n_new := n_new + 1; end if;
    end if;
  end loop;

  update device_sync set
    last_sync_at  = now(),
    last_scan_id  = greatest(last_scan_id, max_id),
    last_log_time = greatest(last_log_time, max_time),
    last_error    = null
  where id = 1;

  return jsonb_build_object('new', n_new, 'unmatched', n_unm,
                            'last_scan_id', (select last_scan_id from device_sync where id = 1));
end $$;

-- ตัวส่งข้อมูลถามว่าควรดึงต่อจาก id ไหน
create or replace function hip_last_scan_id(p_secret text)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from app_secrets
                 where name = 'hip_agent'
                   and secret_hash = encode(digest(p_secret, 'sha256'), 'hex')) then
    raise exception 'unauthorized';
  end if;
  return (select last_scan_id from device_sync where id = 1);
end $$;

-- เมื่อแอดมินใส่รหัส HIP ให้เจ้าหน้าที่ภายหลัง: ย้ายรายการที่ค้างเข้าระบบ
create or replace function hip_rematch() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  with moved as (
    delete from hip_unmatched u using staff s
    where s.hip_user_id = u.enroll_number and s.is_active
    returning u.*, s.id as staff_id
  )
  insert into attendance_logs (staff_id, log_time, method, hip_scan_id, hip_verify)
  select staff_id, log_time, hip_method(null, split_part(hip_verify, ':', 2)), hip_scan_id, hip_verify
  from moved
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 8) ใบบัญชีลงเวลารายวัน — ครบทุกคน รวมคนที่ไม่ได้สแกน
--    เวลามา = สแกนแรก, เวลากลับ = สแกนสุดท้าย (ต้องสแกน ≥ 2 ครั้ง)
-- ---------------------------------------------------------------------
create or replace function daily_sheet(p_day date)
returns table (
  sort_order int, full_name text, staff_type text,
  time_in time, method_in text, time_out time, method_out text,
  is_late boolean, status text, remark text
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
           case when sc.ts is not null and cardinality(sc.ts) = 1 then 'ไม่ได้สแกนกลับ' end)
  from staff st
  left join scans sc on sc.staff_id = st.id
  left join leave_records lv on lv.staff_id = st.id and lv.day = p_day
  where st.is_active
  order by st.sort_order, st.full_name;
$$;

-- สรุปท้ายใบ 7 ข้อ ตามแบบฟอร์มต้นฉบับ
create or replace function daily_summary(p_day date)
returns table (total int, vacancies int, seconded int, present int, absent int, late int, official int)
language sql stable security invoker set search_path = public as $$
  select count(*) filter (where staff_type = 'civil')::int,
         (select vacancies from settings where id = 1),
         count(*) filter (where staff_type = 'seconded')::int,
         count(*) filter (where status = 'present')::int,
         count(*) filter (where status = 'absent')::int,
         count(*) filter (where is_late)::int,
         count(*) filter (where status = 'official')::int
  from daily_sheet(p_day);
$$;

-- ---------------------------------------------------------------------
-- 9) Row Level Security
-- ---------------------------------------------------------------------
alter table staff           enable row level security;
alter table face_templates  enable row level security;
alter table settings        enable row level security;
alter table holidays        enable row level security;
alter table leave_records   enable row level security;
alter table attendance_logs enable row level security;
alter table device_sync     enable row level security;
alter table notify_log      enable row level security;
alter table hip_unmatched   enable row level security;
alter table app_secrets     enable row level security;

create policy staff_read     on staff for select using (auth.uid() is not null);  -- รายชื่อใช้ในใบบัญชี
create policy staff_admin    on staff for all    using (is_admin()) with check (is_admin());

create policy face_own_read  on face_templates for select using (staff_id = my_staff_id() or is_admin());
create policy face_admin     on face_templates for all    using (is_admin()) with check (is_admin());

create policy settings_read  on settings for select using (auth.uid() is not null);
create policy settings_admin on settings for all    using (is_admin()) with check (is_admin());
create policy holidays_read  on holidays for select using (auth.uid() is not null);
create policy holidays_admin on holidays for all    using (is_admin()) with check (is_admin());

create policy leave_read     on leave_records for select using (staff_id = my_staff_id() or is_admin());
create policy leave_admin    on leave_records for all    using (is_admin()) with check (is_admin());

create policy logs_read      on attendance_logs for select using (staff_id = my_staff_id() or is_admin());
create policy logs_admin     on attendance_logs for all    using (is_admin()) with check (is_admin());
-- เจ้าหน้าที่เพิ่มรายการมือถือผ่าน mobile_check_in() เท่านั้น

create policy sync_read      on device_sync for select using (is_admin());
create policy unmatched_admin on hip_unmatched for all using (is_admin()) with check (is_admin());
-- notify_log, app_secrets: ไม่มี policy = เข้าถึงได้เฉพาะ service role / ฟังก์ชัน security definer

-- ---------------------------------------------------------------------
-- 10) สิทธิ์ (ปิด "Automatically expose new tables" ไว้ จึงต้อง GRANT เอง)
--     RLS ข้างบนเป็นตัวกรองแถวอีกชั้น
-- ---------------------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant select, insert, update, delete on
  staff, face_templates, settings, holidays, leave_records,
  attendance_logs, device_sync, hip_unmatched
  to authenticated;

grant execute on function
  is_admin(), my_staff_id(), distance_m(float8, float8, float8, float8),
  hip_method(int, text),
  mobile_check_in(text, float8, float8, text, text, float8),
  daily_sheet(date), daily_summary(date), hip_rematch()
  to authenticated;

-- ตัวส่งข้อมูลบนเครื่อง HIP Time ใช้ anon key + รหัสลับ เรียกได้แค่ 2 ฟังก์ชันนี้
grant execute on function hip_ingest(text, jsonb), hip_last_scan_id(text) to anon;

-- ---------------------------------------------------------------------
-- 11) ตั้งรหัสลับของตัวส่งข้อมูล — รันแยกทีหลัง แทน <รหัสลับ> ด้วยข้อความสุ่มยาว ๆ
--     แล้วใส่รหัสเดียวกันในไฟล์ตั้งค่าของตัวส่งข้อมูลบนเครื่อง HIP Time
--   insert into app_secrets (name, secret_hash)
--   values ('hip_agent', encode(extensions.digest('<รหัสลับ>', 'sha256'), 'hex'))
--   on conflict (name) do update set secret_hash = excluded.secret_hash;
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 12) ส่วนที่ทำในเฟสถัดไป (ไม่อยู่ในไฟล์นี้)
--   * Edge Function ส่ง Telegram: คนมาสาย + สรุปรายวัน 16:30 (pg_cron)
--   * Storage bucket "selfies" แบบ private
-- ---------------------------------------------------------------------
