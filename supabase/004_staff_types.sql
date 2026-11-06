-- 004 — เพิ่มประเภทบุคลากร: พนักงานกระทรวงสาธารณสุข, ลูกจ้างชั่วคราว
alter table staff drop constraint if exists staff_staff_type_check;
alter table staff add constraint staff_staff_type_check
  check (staff_type in ('civil', 'seconded', 'moph_employee', 'temp', 'other'));
-- civil=ข้าราชการ, seconded=ยืมตัวมาช่วยราชการ, moph_employee=พนักงานกระทรวงสาธารณสุข,
-- temp=ลูกจ้างชั่วคราว, other=อื่น ๆ
