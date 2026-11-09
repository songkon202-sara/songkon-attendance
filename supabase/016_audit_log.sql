-- =====================================================================
-- 016 — บันทึกการใช้งาน (Audit Log)
--   บันทึกอัตโนมัติว่าใครทำอะไรเมื่อไร: เพิ่ม/แก้/ลบเจ้าหน้าที่, ลา/ไปราชการ, วันหยุด, ตั้งค่า,
--   ลงเวลาผ่านมือถือ, ลบ/แก้เวลาที่ลงไว้, ลงทะเบียน/ลบ/อนุมัติใบหน้า, เข้าสู่ระบบ, พิมพ์/ดาวน์โหลดรายงาน
--   (สแกนจากเครื่อง HIP ไม่บันทึกทีละรายการ เพราะมีจำนวนมากและเป็นข้อมูลต้นฉบับอยู่แล้ว)
--   แก้ไข/ลบบันทึกนี้ผ่านหน้าเว็บไม่ได้ — ผู้ดูแลและผู้บริหารดูได้อย่างเดียว
-- รันใน Supabase SQL Editor ต่อจาก 015
-- =====================================================================

create table if not exists audit_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  user_id    uuid,
  actor      text not null,
  entity     text not null,   -- staff / leave / holiday / settings / attendance / face / auth / report
  action     text not null,   -- insert / update / delete / login / approve / print / export ...
  summary    text,
  detail     jsonb
);
create index if not exists audit_log_at_idx on audit_log (at desc);
create index if not exists audit_log_entity_idx on audit_log (entity, at desc);

alter table audit_log enable row level security;
drop policy if exists audit_read on audit_log;
create policy audit_read on audit_log for select using (can_view_all());
revoke insert, update, delete on audit_log from anon, authenticated;
grant select on audit_log to authenticated;

-- ชื่อผู้กระทำ: ชื่อเจ้าหน้าที่ของบัญชีที่ล็อกอิน → อีเมล → "ระบบ" (งานอัตโนมัติ / SQL Editor / ตัวส่งข้อมูล HIP)
create or replace function audit_actor() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select full_name from staff where auth_user_id = auth.uid()),
    (select email::text from auth.users where id = auth.uid()),
    'ระบบ');
$$;

create or replace function audit_write(p_entity text, p_action text, p_summary text, p_detail jsonb default null)
returns void
language sql security definer set search_path = public as $$
  insert into audit_log (user_id, actor, entity, action, summary, detail)
  values (auth.uid(), audit_actor(), p_entity, p_action, p_summary, p_detail);
$$;
revoke all on function audit_write(text, text, text, jsonb) from public, anon, authenticated;

-- ฟิลด์ที่เปลี่ยน {ฟิลด์: [เดิม, ใหม่]}
create or replace function audit_diff(o jsonb, n jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_array(o -> k, n -> k)), '{}'::jsonb)
  from jsonb_object_keys(coalesce(n, o)) k
  where (o -> k) is distinct from (n -> k) and k not in ('created_at', 'updated_at', 'descriptor');
$$;

create or replace function audit_name(p_staff uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select full_name from staff where id = p_staff), '?');
$$;

-- ---------------------------------------------------------------------
-- ทริกเกอร์
-- ---------------------------------------------------------------------
create or replace function audit_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  act text := lower(tg_op);
  ent text; summ text; det jsonb;
begin
  if tg_table_name = 'staff' then
    ent := 'staff'; summ := r ->> 'full_name';
    det := case when tg_op = 'UPDATE' then audit_diff(o, n) else r - 'auth_user_id' end;
    if tg_op = 'UPDATE' and det = '{}'::jsonb then return null; end if;
  elsif tg_table_name = 'leave_records' then
    ent := 'leave';
    summ := audit_name((r ->> 'staff_id')::uuid) || ' · ' || (r ->> 'day') || ' · ' ||
            case r ->> 'kind' when 'leave' then 'ลา' when 'official' then 'ไปราชการ' else 'อื่น ๆ' end ||
            coalesce(' (' || nullif(r ->> 'note', '') || ')', '');
    det := case when tg_op = 'UPDATE' then audit_diff(o, n) end;
  elsif tg_table_name = 'holidays' then
    ent := 'holiday'; summ := (r ->> 'day') || ' · ' || coalesce(r ->> 'name', '');
    det := case when tg_op = 'UPDATE' then audit_diff(o, n) end;
  elsif tg_table_name = 'settings' then
    ent := 'settings'; summ := 'ตั้งค่าระบบ'; det := audit_diff(o, n);
    if det = '{}'::jsonb then return null; end if;
  elsif tg_table_name = 'attendance_logs' then
    -- สแกนจากเครื่อง HIP เข้ามาใหม่ไม่ต้องบันทึก (มาจากเครื่องโดยตรง)
    if tg_op = 'INSERT' and r ->> 'method' <> 'mobile' then return null; end if;
    if tg_op = 'UPDATE' then
      det := audit_diff(o, n);
      if det = '{}'::jsonb then return null; end if;
    end if;
    ent := 'attendance';
    summ := audit_name((r ->> 'staff_id')::uuid) || ' · ' ||
            to_char(((r ->> 'log_time')::timestamptz) at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI') || ' · ' ||
            case r ->> 'method' when 'mobile' then 'มือถือ' when 'finger' then 'ลายนิ้วมือ' when 'face' then 'ใบหน้า'
              when 'card' then 'บัตร' when 'password' then 'รหัส' else 'อื่น ๆ' end ||
            case when r ->> 'method' = 'mobile' then
              case when (r ->> 'in_area')::boolean then ' · ในพื้นที่' else ' · นอกพื้นที่ (' || coalesce(r ->> 'reason', '') || ')' end
            else '' end;
    if det is null and tg_op = 'INSERT' then
      det := jsonb_build_object('direction', r -> 'direction', 'distance_m', r -> 'distance_m',
                                'face_score', r -> 'face_score', 'gps_accuracy_m', r -> 'gps_accuracy_m');
    end if;
  else
    return null;
  end if;
  perform audit_write(ent, act, summ, det);
  return null;
end $$;

drop trigger if exists audit_staff on staff;
create trigger audit_staff after insert or update or delete on staff for each row execute function audit_trg();
drop trigger if exists audit_leave on leave_records;
create trigger audit_leave after insert or update or delete on leave_records for each row execute function audit_trg();
drop trigger if exists audit_holiday on holidays;
create trigger audit_holiday after insert or update or delete on holidays for each row execute function audit_trg();
drop trigger if exists audit_settings on settings;
create trigger audit_settings after update on settings for each row execute function audit_trg();
drop trigger if exists audit_attendance on attendance_logs;
create trigger audit_attendance after insert or update or delete on attendance_logs for each row execute function audit_trg();

-- ใบหน้า: บันทึกครั้งเดียวต่อการลงทะเบียน/ลบ ในแต่ละครั้ง (ไม่ใช่ทีละภาพ)
create or replace function audit_face_once(p_action text, p_staff uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare tx text := txid_current()::text;
begin
  if exists (select 1 from audit_log where entity = 'face' and action = p_action
               and detail ->> 'tx' = tx and detail ->> 'staff' = p_staff::text) then return; end if;
  perform audit_write('face', p_action, audit_name(p_staff) || ' · ' || p_text,
                      jsonb_build_object('tx', tx, 'staff', p_staff));
end $$;

create or replace function audit_face_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if tg_op = 'INSERT' then
    for sid in select distinct staff_id from new_rows loop perform audit_face_once('insert', sid, 'ลงทะเบียนใบหน้า'); end loop;
  elsif tg_op = 'DELETE' then
    for sid in select distinct staff_id from old_rows loop perform audit_face_once('delete', sid, 'ลบใบหน้า'); end loop;
  elsif tg_op = 'UPDATE' then
    for sid in select distinct n.staff_id from new_rows n join old_rows o on o.id = n.id
               where o.approved_at is null and n.approved_at is not null loop
      perform audit_write('face', 'approve', audit_name(sid) || ' · อนุมัติใบหน้า', null);
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists audit_face_ins on face_templates;
drop trigger if exists audit_face_del on face_templates;
drop trigger if exists audit_face_upd on face_templates;
create trigger audit_face_ins after insert on face_templates referencing new table as new_rows
  for each statement execute function audit_face_trg();
create trigger audit_face_del after delete on face_templates referencing old table as old_rows
  for each statement execute function audit_face_trg();
create trigger audit_face_upd after update on face_templates referencing old table as old_rows new table as new_rows
  for each statement execute function audit_face_trg();

-- ---------------------------------------------------------------------
-- เหตุการณ์จากหน้าเว็บ (เข้าสู่ระบบ / พิมพ์ / ดาวน์โหลด / ดูบันทึก) — รับเฉพาะชนิดที่กำหนด
-- ---------------------------------------------------------------------
create or replace function log_event(p_action text, p_summary text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if p_action not in ('login', 'print', 'export', 'view_audit') then raise exception 'ชนิดเหตุการณ์ไม่ถูกต้อง'; end if;
  perform audit_write(case when p_action in ('login', 'view_audit') then 'auth' else 'report' end,
                      p_action, left(p_summary, 200), null);
end $$;
revoke all on function log_event(text, text) from public, anon;
grant execute on function log_event(text, text) to authenticated;
