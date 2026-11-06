-- 008 — ตั้ง Telegram bot token จากหน้าตั้งค่าของเว็บ (แอดมินเท่านั้น) แทนการพิมพ์ใน SQL
create or replace function set_tg_token(p_token text) returns void
language plpgsql security definer set search_path = public, vault as $$
declare t text := trim(p_token);
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if t !~ '^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$' then
    raise exception 'รูปแบบ token ไม่ถูกต้อง: ต้องเป็นตัวเลข ตามด้วย : และตัวอักษรอีกประมาณ 35 ตัว (คัดลอกจาก @BotFather)';
  end if;
  delete from vault.secrets where name = 'telegram_bot_token';
  perform vault.create_secret(t, 'telegram_bot_token');
end $$;

-- สถานะ token (ไม่เปิดเผยตัว token)
create or replace function tg_token_status() returns text
language sql stable security definer set search_path = public, vault as $$
  select case
    when not is_admin() then null
    when not exists (select 1 from vault.decrypted_secrets where name = 'telegram_bot_token') then 'ยังไม่ได้ตั้ง'
    when (select decrypted_secret from vault.decrypted_secrets where name = 'telegram_bot_token' limit 1)
         ~ '^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$' then 'ตั้งแล้ว (รูปแบบถูกต้อง)'
    else 'รูปแบบไม่ถูกต้อง — กรุณาวาง token ใหม่'
  end;
$$;

-- ผลการส่งล่าสุดจาก Telegram (ไว้แสดงในหน้าตั้งค่า)
create or replace function tg_last_result() returns text
language sql stable security definer set search_path = public, net as $$
  select case when not is_admin() then null else
    (select coalesce(status_code::text, 'ไม่มีคำตอบ') || ' ' || coalesce(left(content, 160), error_msg, '')
     from net._http_response order by id desc limit 1) end;
$$;

revoke all on function set_tg_token(text), tg_token_status(), tg_last_result() from public, anon;
grant execute on function set_tg_token(text), tg_token_status(), tg_last_result() to authenticated;
