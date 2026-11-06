-- =====================================================================
-- 003 — รายการตำแหน่ง + ลบเจ้าหน้าที่แบบปลอดภัย
-- รันใน Supabase SQL Editor ต่อจาก 002_phase2.sql
-- =====================================================================

-- รายการตำแหน่งสำหรับช่องเลือก (แอดมินแก้ได้ในหน้าตั้งค่า / พิมพ์ตำแหน่งใหม่แล้วระบบเพิ่มให้)
alter table settings add column if not exists positions text[] not null default array[
  'ผู้อำนวยการ รพ.สต.',
  'นักวิชาการสาธารณสุข',
  'พยาบาลวิชาชีพ',
  'เจ้าพนักงานสาธารณสุข',
  'เจ้าพนักงานทันตสาธารณสุข',
  'แพทย์แผนไทย',
  'นักการแพทย์แผนไทย',
  'เจ้าพนักงานธุรการ',
  'ผู้ช่วยเจ้าหน้าที่สาธารณสุข',
  'พนักงานบริการ'
];

-- จำนวนรายการสแกนของเจ้าหน้าที่แต่ละคน (ใช้ตัดสินว่าลบถาวรได้ไหม)
create or replace function staff_scan_counts()
returns table (staff_id uuid, scans bigint)
language sql stable security definer set search_path = public as $$
  select s.id, (select count(*) from attendance_logs l where l.staff_id = s.id)
  from staff s
  where is_admin();
$$;

-- ลบถาวร: ทำได้เฉพาะคนที่ไม่มีประวัติสแกนและไม่ได้ผูกบัญชีของตัวเองอยู่
-- (คนที่มีประวัติ ให้ "เลิกใช้งาน" แทน เพื่อเก็บใบบัญชีย้อนหลังไว้)
create or replace function delete_staff_if_unused(p_staff_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if p_staff_id = my_staff_id() then raise exception 'ลบบัญชีของตัวเองไม่ได้'; end if;
  if exists (select 1 from attendance_logs where staff_id = p_staff_id) then
    raise exception 'เจ้าหน้าที่คนนี้มีประวัติลงเวลา ให้ใช้ "เลิกใช้งาน" แทน';
  end if;
  delete from leave_records where staff_id = p_staff_id;
  delete from staff where id = p_staff_id;
end $$;

revoke all on function staff_scan_counts(), delete_staff_if_unused(uuid) from public;
grant execute on function staff_scan_counts(), delete_staff_if_unused(uuid) to authenticated;
