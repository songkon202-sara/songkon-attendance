-- =====================================================================
-- 002 — เฟส 2: ผูกบัญชีผู้ใช้กับเจ้าหน้าที่ + นำเข้ารายชื่อจาก HIP Time
-- รันใน Supabase SQL Editor หลัง schema.sql (ฉบับที่ 3)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) บัญชีที่ไม่ต้องแสดงในใบบัญชี (เช่น บัญชีผู้ดูแลระบบที่ไม่ใช่เจ้าหน้าที่ประจำ)
-- ---------------------------------------------------------------------
alter table staff add column if not exists on_sheet boolean not null default true;

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
  where st.is_active and st.on_sheet
  order by st.sort_order, st.full_name;
$$;

-- ---------------------------------------------------------------------
-- 1) รายชื่อจากโปรแกรม HIP Time (ตาราง Student) ที่ตัวส่งข้อมูลส่งขึ้นมา
-- ---------------------------------------------------------------------
create table if not exists hip_people (
  enroll_number text primary key,
  name          text,
  active        boolean,
  updated_at    timestamptz not null default now()
);
alter table hip_people enable row level security;
create policy hip_people_admin on hip_people for select using (is_admin());
grant select on hip_people to authenticated;

create or replace function hip_people_upsert(p_secret text, p_rows jsonb)
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  if not exists (select 1 from app_secrets
                 where name = 'hip_agent'
                   and secret_hash = encode(digest(p_secret, 'sha256'), 'hex')) then
    raise exception 'unauthorized';
  end if;
  insert into hip_people (enroll_number, name, active, updated_at)
  select r->>'enroll', nullif(trim(r->>'name'), ''), coalesce((r->>'active')::boolean, true), now()
  from jsonb_array_elements(p_rows) r
  where coalesce(r->>'enroll', '') <> ''
  on conflict (enroll_number) do update
    set name = excluded.name, active = excluded.active, updated_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

-- แอดมินกด "นำเข้ารายชื่อจาก HIP": สร้างเจ้าหน้าที่ที่ยังไม่มี แล้วย้ายรายการสแกนที่ค้าง
create or replace function import_hip_people() returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_new int; n_moved int;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  insert into staff (hip_user_id, full_name, sort_order)
  select p.enroll_number, coalesce(p.name, 'รหัส ' || p.enroll_number),
         coalesce((select max(sort_order) from staff), 0)
           + row_number() over (order by p.enroll_number::bigint)
  from hip_people p
  where coalesce(p.active, true)
    and not exists (select 1 from staff s where s.hip_user_id = p.enroll_number);
  get diagnostics n_new = row_count;
  n_moved := hip_rematch();
  return jsonb_build_object('new_staff', n_new, 'moved_scans', n_moved);
end $$;

-- ---------------------------------------------------------------------
-- 2) ผูกบัญชีล็อกอิน (auth.users) กับเจ้าหน้าที่
-- ---------------------------------------------------------------------
create or replace function list_unlinked_users()
returns table (user_id uuid, email text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select u.id, u.email::text, u.created_at
  from auth.users u
  where is_admin()
    and not exists (select 1 from staff s where s.auth_user_id = u.id)
  order by u.created_at desc;
$$;

create or replace function link_staff_user(p_staff_id uuid, p_user_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare was_admin boolean;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select bool_or(role = 'admin') into was_admin from staff where auth_user_id = p_user_id;
  update staff set auth_user_id = null where auth_user_id = p_user_id;
  -- ย้ายบัญชีไปแถวใหม่ ถ้าบัญชีนี้เคยเป็นแอดมินก็ให้คงสิทธิ์แอดมินไว้ (กันล็อกตัวเองออก)
  update staff set auth_user_id = p_user_id,
                   role = case when coalesce(was_admin, false) then 'admin' else role end
  where id = p_staff_id;
end $$;

-- อีเมลของบัญชีที่ผูกแล้ว (แสดงในหน้ารายชื่อ)
create or replace function staff_emails()
returns table (staff_id uuid, email text)
language sql stable security definer set search_path = public as $$
  select s.id, u.email::text
  from staff s join auth.users u on u.id = s.auth_user_id
  where is_admin();
$$;

-- สรุปรายการที่จับคู่ไม่ได้ แยกตามรหัส
create or replace view hip_unmatched_summary with (security_invoker = true) as
  select u.enroll_number, count(*) as scans, min(u.log_time) as first_scan, max(u.log_time) as last_scan,
         (select name from hip_people p where p.enroll_number = u.enroll_number) as hip_name
  from hip_unmatched u
  group by u.enroll_number;

-- ---------------------------------------------------------------------
-- 3) สิทธิ์
-- ---------------------------------------------------------------------
revoke all on function hip_people_upsert(text, jsonb), import_hip_people(),
  list_unlinked_users(), link_staff_user(uuid, uuid), staff_emails() from public;
grant execute on function hip_people_upsert(text, jsonb) to anon;
grant execute on function import_hip_people(), list_unlinked_users(),
  link_staff_user(uuid, uuid), staff_emails() to authenticated;
grant select on hip_unmatched_summary to authenticated;

-- ---------------------------------------------------------------------
-- 4) ตั้งแอดมินคนแรก — รันแยกหลังสมัครบัญชีบนหน้าเว็บแล้ว (แทนอีเมล)
--   insert into staff (full_name, role, on_sheet, auth_user_id)
--   select 'ผู้ดูแลระบบ', 'admin', false, id from auth.users where email = '<อีเมลแอดมิน>'
--   on conflict do nothing;
--   (ถ้าเจ้าหน้าที่คนนั้นมีอยู่แล้ว ให้ผูกบัญชีจากหน้าเว็บแทน แล้วเปลี่ยนบทบาทเป็น admin)
-- ---------------------------------------------------------------------
