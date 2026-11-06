-- =====================================================================
-- 013 — รวมรายชื่อซ้ำ + ใช้รหัสให้ตรงกับเครื่องสแกน
--   • ชื่อเดียวกันมี 2 แถว → เก็บแถวที่ข้อมูลครบ (มีตำแหน่ง/ผูกบัญชี/ลำดับต้น)
--     ย้ายประวัติสแกน วันลา ใบหน้า มาไว้ที่แถวนั้น แล้วลบแถวซ้ำ
--   • รหัสสแกน = เลขที่ใช้จริงในเครื่องสแกน (จากแถวซ้ำที่นำเข้าจากเครื่อง หรือจับคู่จากชื่อในเครื่อง)
--   • ย้ายรายการสแกนที่ค้าง (ยังไม่รู้ว่าเป็นใคร) เข้าคนที่จับคู่ได้
--
-- วิธีใช้ใน Supabase SQL Editor (รันไฟล์นี้ก่อน 1 ครั้ง)
--   ดูก่อน (ยังไม่แก้อะไร):  select * from songkon_merge(false);
--   ทำจริง:                select * from songkon_merge(true);
-- =====================================================================

-- ชื่อแบบตัดคำนำหน้าและช่องว่าง ใช้เทียบว่าเป็นคนเดียวกัน
create or replace function norm_name(p text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(coalesce(p, ''), '^\s*(นางสาว|น\.ส\.|นส\.?|นาง|นาย|ว่าที่\s*ร\.ต\.)\s*', ''),
           '\s+', '', 'g');
$$;

create or replace function songkon_merge(p_apply boolean default false)
returns table (ชื่อ text, ตำแหน่ง text, รหัสเดิม text, รหัสใหม่ text, แถวซ้ำที่ลบ int, สแกนที่ย้าย int, หมายเหตุ text)
language plpgsql security definer set search_path = public as $$
declare
  k record; d record;
  new_code text; n_dup int; n_logs int; n_tmp int; note text;
begin
  for k in
    select distinct on (norm_name(s.full_name)) s.*
    from staff s where s.is_active
    order by norm_name(s.full_name),
             (s.position is not null) desc, (s.auth_user_id is not null) desc, s.sort_order, s.created_at
  loop
    n_dup := 0; n_logs := 0; note := null;

    -- 1) รหัสจริงในเครื่อง: จากแถวซ้ำ → จากชื่อในเครื่อง → รหัสเดิม (ถ้ามีในเครื่อง)
    select s.hip_user_id into new_code from staff s
      join hip_people h on h.enroll_number = s.hip_user_id
      where s.is_active and s.id <> k.id and norm_name(s.full_name) = norm_name(k.full_name)
      limit 1;
    if new_code is null then
      select h.enroll_number into new_code from hip_people h
        where norm_name(h.name) = norm_name(k.full_name)
          and (select count(*) from hip_people h2 where norm_name(h2.name) = norm_name(k.full_name)) = 1;
    end if;
    if new_code is null and exists (select 1 from hip_people where enroll_number = k.hip_user_id) then
      new_code := k.hip_user_id;
    end if;
    if new_code is null then note := 'ไม่พบชื่อนี้ในเครื่องสแกน — ใส่รหัสเองภายหลัง'; end if;

    -- 2) แถวซ้ำ
    for d in select s.* from staff s
             where s.is_active and s.id <> k.id and norm_name(s.full_name) = norm_name(k.full_name) loop
      n_dup := n_dup + 1;
      select count(*) into n_tmp from attendance_logs where staff_id = d.id;
      n_logs := n_logs + n_tmp;
      if p_apply then
        delete from attendance_logs a using attendance_logs b
          where a.staff_id = d.id and b.staff_id = k.id and a.log_time = b.log_time and a.method = b.method;
        update attendance_logs set staff_id = k.id where staff_id = d.id;
        delete from leave_records a using leave_records b
          where a.staff_id = d.id and b.staff_id = k.id and a.day = b.day;
        update leave_records set staff_id = k.id where staff_id = d.id;
        update leave_records set created_by = k.id where created_by = d.id;
        update face_templates set staff_id = k.id where staff_id = d.id;
        if k.auth_user_id is null and d.auth_user_id is not null then
          update staff set auth_user_id = null where id = d.id;
          update staff set auth_user_id = d.auth_user_id where id = k.id;
        end if;
        delete from staff where id = d.id;
      end if;
    end loop;

    -- 3) ตั้งรหัสใหม่ (ปลดรหัสนี้จากคนอื่นก่อน)
    if p_apply and coalesce(new_code, '') is distinct from coalesce(k.hip_user_id, '') then
      update staff set hip_user_id = null where hip_user_id = new_code and id <> k.id;
      update staff set hip_user_id = new_code where id = k.id;
    end if;

    ชื่อ := k.full_name; ตำแหน่ง := k.position; รหัสเดิม := k.hip_user_id; รหัสใหม่ := new_code;
    แถวซ้ำที่ลบ := n_dup; สแกนที่ย้าย := n_logs; หมายเหตุ := note;
    return next;
  end loop;

  -- 4) ย้ายรายการสแกนที่ค้างเข้าคนที่มีรหัสแล้ว
  if p_apply then
    with moved as (
      delete from hip_unmatched u using staff s
      where s.hip_user_id = u.enroll_number and s.is_active
      returning u.*, s.id as sid
    )
    insert into attendance_logs (staff_id, log_time, method, hip_scan_id, hip_verify)
    select sid, log_time, hip_method(null, split_part(hip_verify, ':', 2)), hip_scan_id, hip_verify
    from moved on conflict do nothing;
  end if;
end $$;

-- รันได้เฉพาะจาก SQL Editor (เจ้าของฐานข้อมูล) — หน้าเว็บเรียกไม่ได้
revoke all on function songkon_merge(boolean) from public, anon, authenticated;
