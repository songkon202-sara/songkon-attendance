-- =====================================================================
-- 010 — ลงเวลาผ่านมือถือ: ลงทะเบียนใบหน้า + ที่เก็บรูปยืนยัน (selfies)
-- รันใน Supabase SQL Editor ต่อจาก 009
-- =====================================================================

-- ลงทะเบียนใบหน้าของตัวเอง (ครั้งแรกเท่านั้น — ลงทะเบียนใหม่ต้องให้แอดมินรีเซ็ตก่อน)
-- p_descriptors = [[128 ค่า], [128 ค่า], ...] จากการถ่าย 3 มุม
create or replace function register_my_face(p_descriptors jsonb)
returns int
language plpgsql security definer set search_path = public as $$
declare me uuid := my_staff_id(); d jsonb; n int := 0;
begin
  if me is null then raise exception 'บัญชีนี้ยังไม่ได้ผูกกับเจ้าหน้าที่'; end if;
  if exists (select 1 from face_templates where staff_id = me) then
    raise exception 'ลงทะเบียนใบหน้าไว้แล้ว ถ้าต้องการลงทะเบียนใหม่ ให้ผู้ดูแลระบบกด "รีเซ็ตใบหน้า"';
  end if;
  if jsonb_typeof(p_descriptors) <> 'array' or jsonb_array_length(p_descriptors) not between 1 and 5 then
    raise exception 'ข้อมูลใบหน้าไม่ถูกต้อง';
  end if;
  for d in select * from jsonb_array_elements(p_descriptors) loop
    if jsonb_array_length(d) <> 128 then raise exception 'ข้อมูลใบหน้าไม่ถูกต้อง'; end if;
    insert into face_templates (staff_id, descriptor, consent_at)
    values (me, array(select (x)::float8 from jsonb_array_elements_text(d) x), now());
    n := n + 1;
  end loop;
  return n;
end $$;

-- แอดมินรีเซ็ตใบหน้าของเจ้าหน้าที่ (เช่น เปลี่ยนโทรศัพท์ / ลงทะเบียนผิด)
create or replace function reset_face(p_staff_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  delete from face_templates where staff_id = p_staff_id;
end $$;

-- รายชื่อคนที่ลงทะเบียนใบหน้าแล้ว (แสดงในหน้าเจ้าหน้าที่)
create or replace function face_status()
returns table (staff_id uuid, registered_at timestamptz)
language sql stable security definer set search_path = public as $$
  select staff_id, min(created_at) from face_templates
  where is_admin() or staff_id = my_staff_id()
  group by staff_id;
$$;

revoke all on function register_my_face(jsonb), reset_face(uuid), face_status() from public, anon;
grant execute on function register_my_face(jsonb), reset_face(uuid), face_status() to authenticated;

-- ---------------------------------------------------------------------
-- ที่เก็บรูปยืนยันตอนลงเวลา (private) — เจ้าหน้าที่อัปโหลดได้เฉพาะโฟลเดอร์ของตัวเอง
-- path: <staff_id>/<YYYY-MM-DD>/<เวลา>.jpg
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('selfies', 'selfies', false, 300000, array['image/jpeg'])
on conflict (id) do nothing;

drop policy if exists selfies_insert_own on storage.objects;
drop policy if exists selfies_read      on storage.objects;
create policy selfies_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'selfies' and (storage.foldername(name))[1] = my_staff_id()::text);
create policy selfies_read on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and (is_admin() or (storage.foldername(name))[1] = my_staff_id()::text));

-- รายการลงเวลาผ่านมือถือของวัน (หน้าแอดมิน: ดูรูปยืนยัน / พิกัด)
create or replace function mobile_logs(p_day date)
returns table (full_name text, log_time timestamptz, direction text, in_area boolean,
               distance_m int, reason text, selfie_path text, face_score float8)
language sql stable security definer set search_path = public as $$
  select st.full_name, l.log_time, l.direction, l.in_area, l.distance_m, l.reason, l.selfie_path, l.face_score
  from attendance_logs l join staff st on st.id = l.staff_id
  where is_admin() and l.method = 'mobile'
    and (l.log_time at time zone 'Asia/Bangkok')::date = p_day
  order by l.log_time;
$$;
revoke all on function mobile_logs(date) from public, anon;
grant execute on function mobile_logs(date) to authenticated;
