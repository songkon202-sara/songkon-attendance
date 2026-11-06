-- =====================================================================
-- 006 — แจ้งเตือน Telegram จาก Supabase (pg_cron + pg_net)
-- รันใน Supabase SQL Editor ต่อจาก 005
--
-- ทุก 15 นาที ฟังก์ชัน tg_tick() จะตัดสินเองตามเวลาไทยและค่าในตั้งค่า:
--   • ลงเวลาใหม่         ระหว่าง 07:30–17:30 (ส่งเฉพาะเมื่อมีรายการใหม่)
--   • มาสาย / ยังไม่ลงเวลา  ครั้งเดียว หลัง work_start + late_grace_min + 15 นาที (ค่าเริ่มต้น 09:00)
--   • สรุปรายวัน          ครั้งเดียว หลัง work_end + 15 นาที (ค่าเริ่มต้น 16:45)
--   ส่งเฉพาะวันทำงาน (settings.workdays) และไม่ใช่วันหยุด (holidays)
--
-- ตั้งค่าหลังรันไฟล์นี้ (ดูขั้นตอนท้ายไฟล์): bot token ใน Vault, chat id และ topic id ใน settings
-- =====================================================================

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- จุดที่ส่ง "ลงเวลาใหม่" ไปแล้ว (นับจากเวลาที่รายการเข้าระบบ)
create table if not exists notify_state (
  id                 int primary key default 1 check (id = 1),
  last_scan_created  timestamptz not null default now()
);
insert into notify_state default values on conflict do nothing;
alter table notify_state enable row level security;   -- ไม่มี policy = ผู้ใช้เว็บเข้าไม่ถึง

-- ---------------------------------------------------------------------
-- ส่งข้อความ
-- ---------------------------------------------------------------------
create or replace function tg_esc(t text) returns text language sql immutable as $$
  select replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

create or replace function tg_send(p_text text) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  s     settings;
  token text;
  body  jsonb;
begin
  select * into s from settings where id = 1;
  if not s.telegram_notify or coalesce(s.telegram_chat_id, '') = '' then return null; end if;
  select decrypted_secret into token from vault.decrypted_secrets where name = 'telegram_bot_token' limit 1;
  if token is null then raise warning 'tg_send: ยังไม่ได้ตั้ง telegram_bot_token ใน Vault'; return null; end if;
  body := jsonb_build_object('chat_id', s.telegram_chat_id, 'text', p_text,
                             'parse_mode', 'HTML', 'disable_web_page_preview', true);
  if coalesce(s.telegram_topic_id, '') <> '' then
    body := body || jsonb_build_object('message_thread_id', s.telegram_topic_id::bigint);
  end if;
  return net.http_post(
    url     := 'https://api.telegram.org/bot' || token || '/sendMessage',
    body    := body,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
end $$;

-- ---------------------------------------------------------------------
-- ข้อความแต่ละแบบ (คืนข้อความ ไม่ส่ง — ใช้ทดสอบได้)
-- ---------------------------------------------------------------------
create or replace function tg_method_th(m text) returns text language sql immutable as $$
  select case m when 'face' then 'ใบหน้า' when 'finger' then 'ลายนิ้วมือ' when 'password' then 'รหัส'
                when 'card' then 'บัตร' when 'mobile' then 'มือถือ' else 'อื่น ๆ' end;
$$;

-- รายการที่เข้าระบบหลัง p_since (เฉพาะเวลาสแกนของวันนี้)
create or replace function tg_msg_new_scans(p_since timestamptz, p_until timestamptz) returns text
language sql stable security definer set search_path = public as $$
  with today as (select (now() at time zone 'Asia/Bangkok')::date as d),
  fresh as (
    select l.*, st.full_name, st.sort_order,
           -- รายการแรกของวันของคนนั้น = มา
           not exists (select 1 from attendance_logs e
                       where e.staff_id = l.staff_id
                         and (e.log_time at time zone 'Asia/Bangkok')::date = (select d from today)
                         and e.log_time < l.log_time) as is_first
    from attendance_logs l join staff st on st.id = l.staff_id
    where l.created_at > p_since and l.created_at <= p_until
      and (l.log_time at time zone 'Asia/Bangkok')::date = (select d from today)
      and st.is_active and st.on_sheet
  )
  select case when count(*) = 0 then null else
    '🕘 <b>ลงเวลาใหม่</b>' || chr(10) ||
    string_agg(
      '• ' || tg_esc(full_name) || ' — ' || to_char(log_time at time zone 'Asia/Bangkok', 'HH24:MI') || ' ' ||
      case when is_first then 'มา' else 'สแกน' end || ' (' || tg_method_th(method) || ')' ||
      case when in_area = false then ' 📍นอกพื้นที่' || coalesce(': ' || tg_esc(reason), '') else '' end,
      chr(10) order by log_time, sort_order)
  end
  from fresh;
$$;

create or replace function tg_msg_late(p_day date) returns text
language sql stable security definer set search_path = public as $$
  with sh as (select * from daily_sheet(p_day)),
  late as (select string_agg('• ' || tg_esc(full_name) || ' — ' || to_char(time_in, 'HH24:MI'), chr(10) order by time_in) t,
                  count(*) n from sh where is_late),
  missing as (select string_agg('• ' || tg_esc(full_name), chr(10) order by sort_order) t, count(*) n
              from sh where status = 'absent' and remark not like '%ลา%')
  select '⏰ <b>สรุปการมาปฏิบัติงาน ' || to_char(p_day, 'DD/MM') || '/' || (extract(year from p_day)::int + 543) || '</b>' || chr(10) ||
         '<b>มาสาย ' || late.n || ' คน</b>' || coalesce(chr(10) || late.t, '') || chr(10) ||
         '<b>ยังไม่ลงเวลา ' || missing.n || ' คน</b>' || coalesce(chr(10) || missing.t, '') ||
         chr(10) || '<i>(ข้อมูลจากเครื่องสแกนที่เข้าระบบแล้ว ณ เวลานี้)</i>'
  from late, missing;
$$;

create or replace function tg_msg_summary(p_day date) returns text
language sql stable security definer set search_path = public as $$
  with sh as (select * from daily_sheet(p_day)),
  sm as (select * from daily_summary(p_day)),
  noout as (select string_agg('• ' || tg_esc(full_name), chr(10) order by sort_order) t, count(*) n
            from sh where status = 'present' and time_out is null),
  away  as (select count(*) n from sh where remark like '%นอกพื้นที่%'),
  lv    as (select count(*) n from sh where remark like 'ลา%')
  select '📋 <b>สรุปรายวัน ' || to_char(p_day, 'DD/MM') || '/' || (extract(year from p_day)::int + 543) || '</b>' || chr(10) ||
         'มาปฏิบัติราชการ ' || sm.present || ' คน' || chr(10) ||
         'มาสาย ' || sm.late || ' คน' || chr(10) ||
         'ไปราชการ ' || sm.official || ' คน' || chr(10) ||
         'ลา ' || lv.n || ' คน · ไม่มา/ไม่ได้ลงเวลา ' || (sm.absent - lv.n) || ' คน' || chr(10) ||
         'ลงเวลานอกพื้นที่ ' || away.n || ' คน' ||
         case when noout.n > 0 then chr(10) || '<b>ยังไม่สแกนกลับ ' || noout.n || ' คน</b>' || chr(10) || noout.t else '' end
  from sm, noout, away, lv;
$$;

-- ---------------------------------------------------------------------
-- ตัวตัดสินใจ — pg_cron เรียกทุก 15 นาที
-- ---------------------------------------------------------------------
create or replace function tg_tick() returns text
language plpgsql security definer set search_path = public as $$
declare
  s      settings;
  nowbk  timestamp := now() at time zone 'Asia/Bangkok';
  d      date := nowbk::date;
  t      time := nowbk::time;
  since  timestamptz;
  upto   timestamptz := now();
  msg    text;
  did    text := '';
begin
  select * into s from settings where id = 1;
  if not s.telegram_notify then return 'ปิดการแจ้งเตือน'; end if;
  if not (extract(isodow from d)::int = any (s.workdays)) or exists (select 1 from holidays where day = d) then
    return 'ไม่ใช่วันทำงาน';
  end if;

  -- 1) ลงเวลาใหม่ (07:30–17:30)
  if t between time '07:30' and time '17:30' then
    select last_scan_created into since from notify_state where id = 1;
    msg := tg_msg_new_scans(since, upto);
    update notify_state set last_scan_created = upto where id = 1;
    if msg is not null then perform tg_send(msg); did := did || 'ลงเวลาใหม่ '; end if;
  else
    update notify_state set last_scan_created = upto where id = 1;
  end if;

  -- 2) มาสาย / ยังไม่ลงเวลา — ครั้งเดียวต่อวัน
  if t >= s.work_start + make_interval(mins => s.late_grace_min + 15)
     and t < s.work_end
     and not exists (select 1 from notify_log where day = d and kind = 'late') then
    perform tg_send(tg_msg_late(d));
    insert into notify_log (day, kind) values (d, 'late');
    did := did || 'มาสาย ';
  end if;

  -- 3) สรุปรายวัน — ครั้งเดียวต่อวัน
  if t >= s.work_end + interval '15 minutes'
     and not exists (select 1 from notify_log where day = d and kind = 'summary') then
    perform tg_send(tg_msg_summary(d));
    insert into notify_log (day, kind) values (d, 'summary');
    did := did || 'สรุปรายวัน ';
  end if;

  return coalesce(nullif(trim(did), ''), 'ไม่มีอะไรต้องส่ง');
end $$;

-- ทดสอบส่งจากหน้าเว็บ (แอดมินเท่านั้น)
create or replace function tg_test() returns bigint
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return tg_send('✅ ทดสอบการแจ้งเตือนจากระบบลงเวลา รพ.สต.สองคอน');
end $$;

revoke all on function tg_send(text), tg_tick(), tg_msg_new_scans(timestamptz, timestamptz),
  tg_msg_late(date), tg_msg_summary(date), tg_test() from public, anon, authenticated;
grant execute on function tg_test() to authenticated;

-- ตั้งเวลา: ทุก 15 นาที (ใช้ชื่อเดิมซ้ำได้ — รันไฟล์นี้ซ้ำจะไม่สร้างงานซ้อน)
select cron.schedule('songkon-telegram', '*/15 * * * *', $$select public.tg_tick()$$);

-- =====================================================================
-- ขั้นตั้งค่า (รันแยก แทนค่าใน <...>)
--
-- 1) เก็บ bot token ใน Vault (ไม่ต้องส่งให้ใคร):
--    select vault.create_secret('<BOT_TOKEN>', 'telegram_bot_token');
--    (ถ้าเคยตั้งแล้วและจะเปลี่ยน: select vault.update_secret(
--       (select id from vault.secrets where name = 'telegram_bot_token'), '<BOT_TOKEN_ใหม่>');)
--
-- 2) ใส่กลุ่มและหัวข้อ แล้วเปิดแจ้งเตือน:
--    update settings set telegram_chat_id = '-100xxxxxxxxxx',
--                        telegram_topic_id = '<เลขหัวข้อ>',
--                        telegram_notify = true where id = 1;
--
-- 3) ทดสอบ: select tg_send('ทดสอบ');   ดูผล: select * from net._http_response order by id desc limit 3;
-- =====================================================================
