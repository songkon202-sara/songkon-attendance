-- 017 — แก้สแกนที่บันทึกปีเป็น พ.ศ. (เช่น 2569 → 2026)
-- รันใน Supabase SQL Editor 1 ครั้ง (รันซ้ำได้ ไม่เสียหาย)
update attendance_logs
   set log_time = ((log_time at time zone 'Asia/Bangkok') - interval '543 years') at time zone 'Asia/Bangkok'
 where extract(year from log_time at time zone 'Asia/Bangkok') > 2400;

update hip_unmatched
   set log_time = ((log_time at time zone 'Asia/Bangkok') - interval '543 years') at time zone 'Asia/Bangkok'
 where extract(year from log_time at time zone 'Asia/Bangkok') > 2400;

update device_sync
   set last_log_time = ((last_log_time at time zone 'Asia/Bangkok') - interval '543 years') at time zone 'Asia/Bangkok'
 where extract(year from last_log_time at time zone 'Asia/Bangkok') > 2400;

select l.hip_scan_id, s.full_name, l.log_time at time zone 'Asia/Bangkok' as เวลา
from attendance_logs l join staff s on s.id = l.staff_id
where l.hip_scan_id >= 3071 order by l.hip_scan_id;
