-- 005 — บัญชีที่ยังไม่ได้ผูกกับเจ้าหน้าที่ อ่านข้อมูลใด ๆ ไม่ได้
-- (ใช้คู่กับการปิด "Confirm email" — ใครสมัครก็ได้ แต่ต้องรอแอดมินผูกบัญชีก่อนถึงจะเห็นข้อมูล)
drop policy if exists staff_read    on staff;
drop policy if exists settings_read on settings;
drop policy if exists holidays_read on holidays;
create policy staff_read    on staff    for select using (my_staff_id() is not null);
create policy settings_read on settings for select using (my_staff_id() is not null);
create policy holidays_read on holidays for select using (my_staff_id() is not null);

-- หน้าเว็บใช้ฟังก์ชันนี้ตรวจว่าบัญชีที่ล็อกอินผูกกับเจ้าหน้าที่แล้วหรือยัง
create or replace function my_staff()
returns setof staff
language sql stable security definer set search_path = public as $$
  select * from staff where auth_user_id = auth.uid() and is_active limit 1;
$$;
revoke all on function my_staff() from public;
grant execute on function my_staff() to authenticated;
