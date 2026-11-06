# ระบบลงเวลาปฏิบัติราชการ รพ.สต.สองคอน

ดึงเวลาสแกนจากเครื่อง HIP (ใบหน้า / ลายนิ้วมือ / รหัส / บัตร) มาออกใบบัญชีลงเวลาตามแบบฟอร์มราชการ

| ส่วน | ที่อยู่ |
|---|---|
| หน้าเว็บ (GitHub Pages) | `index.html`, `app.js`, `app.css`, `config.js` |
| ฐานข้อมูล (Supabase) | `supabase/schema.sql` → `supabase/002_phase2.sql` |
| ตัวส่งข้อมูลจาก HIP Time | `agent/` (ดู `agent/README.md`) |

## เริ่มใช้งานครั้งแรก
1. รัน `supabase/schema.sql` แล้ว `supabase/002_phase2.sql` ใน Supabase SQL Editor
2. ติดตั้งตัวส่งข้อมูลบนเครื่อง HIP Time ด้วย `agent/install.ps1`
3. สมัครบัญชีบนหน้าเว็บ แล้วตั้งแอดมินคนแรกด้วยคำสั่งท้ายไฟล์ `002_phase2.sql`
4. เข้าหน้า "เจ้าหน้าที่" กด "นำเข้ารายชื่อจากเครื่องสแกน" แล้วผูกบัญชีของแต่ละคน

`config.js` มีแค่ URL และ publishable key ของ Supabase ซึ่งเปิดเผยได้ การป้องกันข้อมูลทำด้วย RLS ในฐานข้อมูล
