-- =====================================================================
-- 014 — ยืนยันใบหน้าให้ปลอดภัยขึ้น
--   1) เทียบใบหน้าที่ฐานข้อมูล (ไม่เชื่อผลจากโทรศัพท์) — ยกเลิกฟังก์ชันเดิมที่รับ "คะแนน" จากโทรศัพท์
--   2) ผู้ดูแลเป็นคนลงทะเบียนใบหน้าให้เจ้าหน้าที่ (มีรูปเก็บไว้) — เจ้าหน้าที่ลงทะเบียนเองไม่ได้
--      (ใบหน้าที่ลงทะเบียนไว้ก่อนแล้ว ใช้ต่อได้)
--   3) บันทึกผลตรวจว่าเป็นคนจริง (ท่าทางที่ทำ) และความแม่นของ GPS
-- รันใน Supabase SQL Editor ต่อจาก 013
-- =====================================================================

alter table face_templates  add column if not exists approved_at timestamptz;
alter table face_templates  add column if not exists approved_by uuid references staff(id) on delete set null;
alter table face_templates  add column if not exists photo_path  text;
update face_templates set approved_at = created_at where approved_at is null;

alter table attendance_logs add column if not exists gps_accuracy_m int;
alter table attendance_logs add column if not exists liveness text;

-- ระยะห่างใบหน้า (ยิ่งน้อยยิ่งเหมือน) เทียบกับแม่แบบที่อนุมัติแล้วของคนนั้น
create or replace function face_distance(p_staff uuid, p_desc float8[]) returns float8
language sql stable security definer set search_path = public as $$
  select min(sqrt(d.s)) from (
    select sum((a.v - b.v) ^ 2) as s
    from face_templates t
    cross join lateral unnest(t.descriptor) with ordinality a(v, i)
    join unnest(p_desc) with ordinality b(v, i) on b.i = a.i
    where t.staff_id = p_staff and t.approved_at is not null
    group by t.id
  ) d;
$$;
revoke all on function face_distance(uuid, float8[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- ลงทะเบียนใบหน้า: ผู้ดูแลเป็นคนลงทะเบียนให้ (ใช้เป็นแม่แบบเปรียบเทียบ) — เจ้าหน้าที่ลงเองไม่ได้แล้ว
-- ลงใหม่ = แทนของเดิม
-- ---------------------------------------------------------------------
drop function if exists register_my_face(jsonb);
drop function if exists register_my_face(jsonb, text);
create or replace function admin_register_face(p_staff_id uuid, p_descriptors jsonb, p_photo_path text)
returns int
language plpgsql security definer set search_path = public as $$
declare d jsonb; n int := 0;
begin
  if not is_admin() then raise exception 'เฉพาะผู้ดูแลระบบ'; end if;
  if not exists (select 1 from staff where id = p_staff_id) then raise exception 'ไม่พบเจ้าหน้าที่'; end if;
  if coalesce(p_photo_path, '') not like p_staff_id::text || '/%' then raise exception 'ต้องมีรูปใบหน้าประกอบการลงทะเบียน'; end if;
  if jsonb_typeof(p_descriptors) <> 'array' or jsonb_array_length(p_descriptors) not between 1 and 5 then
    raise exception 'ข้อมูลใบหน้าไม่ถูกต้อง';
  end if;
  delete from face_templates where staff_id = p_staff_id;
  for d in select * from jsonb_array_elements(p_descriptors) loop
    if jsonb_array_length(d) <> 128 then raise exception 'ข้อมูลใบหน้าไม่ถูกต้อง'; end if;
    insert into face_templates (staff_id, descriptor, consent_at, photo_path, approved_at, approved_by)
    values (p_staff_id, array(select (x)::float8 from jsonb_array_elements_text(d) x), now(), p_photo_path, now(), my_staff_id());
    n := n + 1;
  end loop;
  return n;
end $$;

-- ผู้ดูแลอัปโหลดรูปลงทะเบียนเข้าโฟลเดอร์ของเจ้าหน้าที่คนอื่นได้
drop policy if exists selfies_insert_admin on storage.objects;
create policy selfies_insert_admin on storage.objects for insert to authenticated
  with check (bucket_id = 'selfies' and is_admin());

create or replace function approve_face(p_staff_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update face_templates set approved_at = now(), approved_by = my_staff_id()
  where staff_id = p_staff_id and approved_at is null;
end $$;

drop function if exists face_status();
create or replace function face_status()
returns table (staff_id uuid, registered_at timestamptz, approved boolean, photo_path text)
language sql stable security definer set search_path = public as $$
  select staff_id, min(created_at), bool_and(approved_at is not null), max(photo_path)
  from face_templates
  where can_view_all() or staff_id = my_staff_id()
  group by staff_id;
$$;

-- ---------------------------------------------------------------------
-- ลงเวลาผ่านมือถือ: ส่ง "รหัสใบหน้า" มา ฐานข้อมูลเป็นผู้ตัดสิน
-- ---------------------------------------------------------------------
drop function if exists mobile_check_in(text, float8, float8, text, text, float8);
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

drop function if exists mobile_logs(date);
create or replace function mobile_logs(p_day date)
returns table (full_name text, log_time timestamptz, direction text, in_area boolean,
               distance_m int, reason text, selfie_path text, face_score float8,
               gps_accuracy_m int, liveness text)
language sql stable security definer set search_path = public as $$
  select st.full_name, l.log_time, l.direction, l.in_area, l.distance_m, l.reason, l.selfie_path, l.face_score,
         l.gps_accuracy_m, l.liveness
  from attendance_logs l join staff st on st.id = l.staff_id
  where can_view_all() and l.method = 'mobile'
    and (l.log_time at time zone 'Asia/Bangkok')::date = p_day
  order by l.log_time;
$$;

revoke all on function admin_register_face(uuid, jsonb, text), approve_face(uuid), face_status(),
  mobile_check_in(text, float8, float8, text, text, jsonb, float8, text), mobile_logs(date) from public, anon;
grant execute on function admin_register_face(uuid, jsonb, text), approve_face(uuid), face_status(),
  mobile_check_in(text, float8, float8, text, text, jsonb, float8, text), mobile_logs(date) to authenticated;
