-- =====================================================================
-- 011 — สิทธิ์ "ผู้บริหาร (ดูอย่างเดียว)" เช่น ผู้อำนวยการ
--   เห็นข้อมูลทุกคนเหมือนผู้ดูแลระบบ (ใบบัญชี, สรุปรายเดือน, รายชื่อ, ลา/ไปราชการ, รูปยืนยันมือถือ)
--   แต่เพิ่ม / แก้ไข / ลบ อะไรไม่ได้ และไม่เห็นหน้าตั้งค่า
-- รันใน Supabase SQL Editor ต่อจาก 010
-- =====================================================================

-- 1) เพิ่มค่า role = 'viewer'
alter table staff drop constraint if exists staff_role_check;
alter table staff add constraint staff_role_check check (role in ('staff', 'admin', 'viewer'));

-- 2) ใครอ่านข้อมูลทุกคนได้ (ผู้ดูแล + ผู้บริหาร) — สิทธิ์เขียนยังใช้ is_admin() เหมือนเดิม
create or replace function can_view_all() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff
                 where auth_user_id = auth.uid() and role in ('admin', 'viewer') and is_active);
$$;
revoke all on function can_view_all() from public, anon;
grant execute on function can_view_all() to authenticated;

-- 3) นโยบายอ่าน (select เท่านั้น)
drop policy if exists leave_read on leave_records;
create policy leave_read on leave_records for select using (staff_id = my_staff_id() or can_view_all());

drop policy if exists logs_read on attendance_logs;
create policy logs_read on attendance_logs for select using (staff_id = my_staff_id() or can_view_all());

drop policy if exists sync_read on device_sync;
create policy sync_read on device_sync for select using (can_view_all());

drop policy if exists selfies_read on storage.objects;
create policy selfies_read on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and (can_view_all() or (storage.foldername(name))[1] = my_staff_id()::text));

-- 4) ฟังก์ชันอ่านที่เดิมจำกัดเฉพาะแอดมิน
create or replace function staff_emails()
returns table (staff_id uuid, email text)
language sql stable security definer set search_path = public as $$
  select s.id, u.email::text
  from staff s join auth.users u on u.id = s.auth_user_id
  where can_view_all();
$$;

create or replace function staff_scan_counts()
returns table (staff_id uuid, scans bigint)
language sql stable security definer set search_path = public as $$
  select s.id, (select count(*) from attendance_logs l where l.staff_id = s.id)
  from staff s
  where can_view_all();
$$;

create or replace function face_status()
returns table (staff_id uuid, registered_at timestamptz)
language sql stable security definer set search_path = public as $$
  select staff_id, min(created_at) from face_templates
  where can_view_all() or staff_id = my_staff_id()
  group by staff_id;
$$;

create or replace function mobile_logs(p_day date)
returns table (full_name text, log_time timestamptz, direction text, in_area boolean,
               distance_m int, reason text, selfie_path text, face_score float8)
language sql stable security definer set search_path = public as $$
  select st.full_name, l.log_time, l.direction, l.in_area, l.distance_m, l.reason, l.selfie_path, l.face_score
  from attendance_logs l join staff st on st.id = l.staff_id
  where can_view_all() and l.method = 'mobile'
    and (l.log_time at time zone 'Asia/Bangkok')::date = p_day
  order by l.log_time;
$$;
