-- =====================================================================
-- 013 — รวมรายชื่อซ้ำ + ยึดรหัสพนักงาน 01–10 (รายชื่อที่ข้อมูลครบ)
--   • ชื่อเดียวกันมี 2 แถว → เก็บแถวที่ข้อมูลครบ (มีตำแหน่ง/ผูกบัญชี/ลำดับต้น)
--     ย้ายประวัติสแกน วันลา ใบหน้า มาไว้ที่แถวนั้น แล้วลบแถวซ้ำ
--   • รหัสพนักงาน 01–10 เก็บในช่อง emp_code (แสดงในหน้าเว็บ)
--   • เลขในเครื่องสแกน = รหัสพนักงานแบบไม่มีเลข 0 นำหน้า (01 → 1, 10 → 10)
--     ใช้คู่กับการลบผู้ใช้ในเครื่องสแกน แล้วลงทะเบียนใหม่ด้วยเลขชุดนี้
--
-- วิธีใช้ใน Supabase SQL Editor (รันไฟล์นี้ก่อน 1 ครั้ง)
--   ดูก่อน (ยังไม่แก้อะไร):  select * from songkon_merge(false);
--   ทำจริง:                select * from songkon_merge(true);
-- =====================================================================

-- รหัสพนักงานที่ รพ.สต. ตั้งเอง (แยกจากเลขในเครื่องสแกน)
alter table staff add column if not exists emp_code text unique;

-- ชื่อแบบตัดคำนำหน้าและช่องว่าง ใช้เทียบว่าเป็นคนเดียวกัน
create or replace function norm_name(p text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(coalesce(p, ''), '^\s*(นางสาว|น\.ส\.|นส\.?|นาง|นาย|ว่าที่\s*ร\.ต\.)\s*', ''),
           '\s+', '', 'g');
$$;

drop function if exists songkon_merge(boolean);
create or replace function songkon_merge(p_apply boolean default false)
returns table (ชื่อ text, ตำแหน่ง text, รหัสพนักงาน text, เลขในเครื่องสแกน text, แถวซ้ำที่ลบ int, สแกนที่ย้าย int, หมายเหตุ text)
language plpgsql security definer set search_path = public as $$
declare
  k record; d record;
  new_code text; emp text; n_dup int; n_logs int; n_tmp int; note text;
begin
  for k in
    select distinct on (norm_name(s.full_name)) s.*
    from staff s where s.is_active
    order by norm_name(s.full_name),
             (s.position is not null) desc, (s.auth_user_id is not null) desc, s.sort_order, s.created_at
  loop
    n_dup := 0; n_logs := 0; note := null;

    -- 1) รหัสพนักงาน = รหัสที่ตั้งไว้ในแถวที่ข้อมูลครบ, เลขในเครื่อง = ตัดเลข 0 นำหน้า
    emp := case when k.position is not null then coalesce(k.emp_code, k.hip_user_id) else k.emp_code end;
    new_code := case when emp is not null then nullif(regexp_replace(emp, '^0+', ''), '') else k.hip_user_id end;
    if new_code is null then note := 'ยังไม่มีรหัส — ใส่เองในหน้าเจ้าหน้าที่'; end if;

    -- 2) แถวซ้ำ
    for d in select s.* from staff s
             where s.is_active and s.id <> k.id and norm_name(s.full_name) = norm_name(k.full_name) loop
      n_dup := n_dup + 1;
      select count(*) into n_tmp from attendance_logs where staff_id = d.id;
      n_logs := n_logs + n_tmp;
      -- สแกนเก่าที่ค้างอยู่ด้วยเลขเดิมของแถวซ้ำ (เลขในเครื่องชุดเก่า) → ย้ายเข้าคนนี้
      select count(*) into n_tmp from hip_unmatched where d.hip_user_id is not null and enroll_number = d.hip_user_id;
      n_logs := n_logs + n_tmp;
      if p_apply then
        delete from attendance_logs a using attendance_logs b
          where a.staff_id = d.id and b.staff_id = k.id and a.log_time = b.log_time and a.method = b.method;
        update attendance_logs set staff_id = k.id where staff_id = d.id;
        with moved as (
          delete from hip_unmatched u where d.hip_user_id is not null and u.enroll_number = d.hip_user_id returning u.*
        )
        insert into attendance_logs (staff_id, log_time, method, hip_scan_id, hip_verify)
        select k.id, log_time, hip_method(null, split_part(hip_verify, ':', 2)), hip_scan_id, hip_verify
        from moved on conflict do nothing;
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

    -- 3) เก็บรหัสที่ตั้งไว้ (01–10) เป็นรหัสพนักงาน แล้วตั้งเลขในเครื่องสแกน (ปลดเลขนี้จากคนอื่นก่อน)
    if p_apply and emp is not null and k.emp_code is distinct from emp then
      update staff set emp_code = null where emp_code = emp and id <> k.id;
      update staff set emp_code = emp where id = k.id;
    end if;
    if p_apply and coalesce(new_code, '') is distinct from coalesce(k.hip_user_id, '') then
      update staff set hip_user_id = null where hip_user_id = new_code and id <> k.id;
      update staff set hip_user_id = new_code where id = k.id;
    end if;

    ชื่อ := k.full_name; ตำแหน่ง := k.position;
    รหัสพนักงาน := emp;
    เลขในเครื่องสแกน := new_code;
    แถวซ้ำที่ลบ := n_dup; สแกนที่ย้าย := n_logs; หมายเหตุ := note;
    return next;
  end loop;

  -- 4) สแกนเก่าที่ยังค้าง (เลขชุดเดิม) ติดป้าย "เดิม-" กันไม่ให้ไปเข้าคนที่ได้เลขนี้ในชุดใหม่
  if p_apply then
    update hip_unmatched set enroll_number = 'เดิม-' || enroll_number where enroll_number not like 'เดิม-%';
  end if;
  ชื่อ := '(สแกนเก่าที่ยังไม่รู้ว่าเป็นใคร)'; ตำแหน่ง := null; รหัสพนักงาน := null; เลขในเครื่องสแกน := null; แถวซ้ำที่ลบ := 0;
  select count(*) into สแกนที่ย้าย from hip_unmatched u
   where not exists (select 1 from staff s where s.is_active and s.hip_user_id = u.enroll_number
                       and exists (select 1 from staff k2 where k2.is_active and k2.id <> s.id and norm_name(k2.full_name) = norm_name(s.full_name)));
  หมายเหตุ := 'เก็บไว้ในรายการค้าง (ติดป้าย เดิม-) ย้ายเข้าชื่อทีหลังได้';
  return next;

end $$;

-- รันได้เฉพาะจาก SQL Editor (เจ้าของฐานข้อมูล) — หน้าเว็บเรียกไม่ได้
revoke all on function songkon_merge(boolean) from public, anon, authenticated;
