# ตัวส่งข้อมูลจาก HIP Time

ติดตั้งบนเครื่อง Windows ที่มีโปรแกรม HIP Time 4.0 (ฐานข้อมูล SQL Server `hiptime`)

| ไฟล์ | หน้าที่ |
|---|---|
| `install.ps1` | ติดตั้งครั้งเดียว: สร้างบัญชี SQL อ่านอย่างเดียว, สร้างรหัสลับ, ตั้ง Task Scheduler |
| `hip-sync.ps1` | ทำงานทุก 5 นาที: อ่าน `Transcantime` + `Student` แล้วส่งขึ้น Supabase |
| `check-hiptime.ps1` | ตรวจโครงสร้างฐานข้อมูล (อ่านอย่างเดียว) |

## ติดตั้ง
```
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\songkon-sync\install.ps1"
```
ระหว่างติดตั้งจะมีคำสั่ง SQL หนึ่งบรรทัดให้นำไปรันใน Supabase SQL Editor (เป็นค่า hash ของรหัสลับ)

## ความปลอดภัย
- อ่านอย่างเดียว: บัญชี `songkon_sync` มีสิทธิ์ `SELECT` เฉพาะ `dbo.Transcantime`, `dbo.Student`
- รหัสผ่าน SQL และรหัสลับเก็บใน `%LOCALAPPDATA%\SongkonSync\config.json` เข้ารหัสด้วย Windows DPAPI (ถอดได้เฉพาะผู้ใช้ Windows คนเดียวกันบนเครื่องนี้)
- ฝั่ง Supabase ตัวส่งข้อมูลเรียกได้แค่ `hip_ingest`, `hip_last_scan_id`, `hip_people_upsert` และทุกครั้งต้องมีรหัสลับ
- ไม่มีไฟล์ใดในโฟลเดอร์นี้เก็บรหัสผ่านหรือรหัสลับ (`config.json` อยู่ใน `.gitignore`)

## ตรวจสถานะ / แก้ปัญหา
- ล็อก: `%LOCALAPPDATA%\SongkonSync\sync.log`
- รันมือ: `powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SongkonSync\hip-sync.ps1" -Show`
- ยกเลิก: `Unregister-ScheduledTask -TaskName SongkonHipSync`
- ข้อมูลจะเข้าระบบได้ต่อเมื่อโปรแกรม HIP Time ดึงข้อมูลจากเครื่องสแกนแล้ว (ตั้งเวลาไว้ในเมนู "ตั้งเวลาดึงข้อมูลจากเครื่องบันทึกเวลา")
