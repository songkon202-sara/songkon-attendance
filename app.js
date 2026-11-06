/* ระบบลงเวลาปฏิบัติราชการ รพ.สต.สองคอน — หน้าเว็บ (เฟส 2) */
(function () {
  'use strict';
  const cfg = window.APP_CONFIG;
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.publishableKey);
  const $app = document.getElementById('app');
  const state = { user: null, me: null, settings: null };

  // ---------------------------------------------------------------- helpers
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const METHOD = { face: 'ใบหน้า', finger: 'ลายนิ้วมือ', password: 'รหัส', card: 'บัตร', other: 'อื่น ๆ', mobile: 'มือถือ' };
  const TYPE = { civil: 'ข้าราชการ', moph_employee: 'พนักงานกระทรวงสาธารณสุข', temp: 'ลูกจ้างชั่วคราว', seconded: 'ยืมตัวมาช่วยราชการ', other: 'อื่น ๆ' };
  const LEAVE = { leave: 'ลา', official: 'ไปราชการ', other: 'อื่น ๆ' };
  const hhmm = (t) => (t ? String(t).slice(0, 5) : '');
  const todayISO = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
  const thaiDate = (iso, opts) => new Date(iso + 'T00:00:00+07:00').toLocaleDateString('th-TH', Object.assign({ timeZone: 'Asia/Bangkok', day: 'numeric', month: 'long', year: 'numeric' }, opts || {}));
  const thaiDateTime = (ts) => (ts ? new Date(ts).toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'medium', timeStyle: 'short' }) : '—');
  const isAdmin = () => state.me && state.me.role === 'admin';
  // ผู้บริหาร (เช่น ผู้อำนวยการ) เห็นข้อมูลทุกคนเหมือนแอดมิน แต่แก้ไขไม่ได้
  const canView = () => state.me && (state.me.role === 'admin' || state.me.role === 'viewer');
  const ROLE = { staff: 'เจ้าหน้าที่', viewer: 'ผู้บริหาร (ดูอย่างเดียว)', admin: 'ผู้ดูแลระบบ' };

  function toast(msg) {
    const t = document.getElementById('toast');
    t.textContent = msg; t.classList.add('on');
    clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.remove('on'), 2600);
  }
  function fail(err) {
    console.error(err);
    const m = (err && (err.message || err.error_description)) || String(err);
    toast('ทำไม่สำเร็จ: ' + m);
  }
  async function q(promise) {
    const { data, error } = await promise;
    if (error) throw error;
    return data;
  }
  function busy(btn, on) { if (btn) { btn.disabled = on; } }
  function setView(html) { $app.innerHTML = html; $app.focus({ preventScroll: true }); }

  // ---------------------------------------------------------------- routing
  const ROUTES = {
    sheet: { view: true, live: true, title: 'ใบบัญชีลงเวลา', admin: true, render: viewSheet },
    staff: { view: true, title: 'เจ้าหน้าที่', admin: true, render: viewStaff },
    monthly: { view: true, title: 'สรุปรายเดือน', admin: true, render: viewMonthly },
    leave: { view: true, title: 'ลา / ไปราชการ', admin: true, render: viewLeave },
    settings: { title: 'ตั้งค่า', admin: true, render: viewSettings },
    checkin: { title: 'ลงเวลา (มือถือ)', admin: false, render: viewCheckin },
    me: { live: true, title: 'เวลาของฉัน', admin: false, render: viewMe }
  };

  function renderNav(current) {
    const keys = isAdmin() ? ['sheet', 'monthly', 'staff', 'leave', 'settings', 'checkin', 'me']
      : canView() ? ['sheet', 'monthly', 'staff', 'leave', 'checkin', 'me'] : ['checkin', 'me'];
    document.getElementById('nav').innerHTML = keys.map((k) =>
      `<a href="#/${k}"${k === current ? ' aria-current="page"' : ''}>${ROUTES[k].title}</a>`).join('');
  }

  async function route() {
    if (!state.user) return viewLogin();
    if (!state.me) return viewPending();
    const home = canView() ? 'sheet' : 'checkin';
    let key = (location.hash.replace(/^#\/?/, '').split('?')[0]) || home;
    const allowed = (r) => r && (!r.admin || isAdmin() || (r.view && canView()));
    if (!allowed(ROUTES[key])) key = home;
    if (key !== 'checkin') stopCamera();
    document.title = ROUTES[key].title + ' · ระบบลงเวลา รพ.สต.สองคอน';
    renderNav(key);
    clearTimeout(route._t);
    try { await ROUTES[key].render(); } catch (e) { fail(e); }
    if (ROUTES[key].live) scheduleLive(location.hash);
  }

  // หน้าใบบัญชี / เวลาของฉัน: โหลดข้อมูลใหม่เองทุก 1 นาที
  // (ข้ามรอบถ้าแท็บไม่ได้เปิดดูอยู่ หรือกำลังพิมพ์/เลือกอะไรอยู่)
  function scheduleLive(hash) {
    clearTimeout(route._t);
    route._t = setTimeout(() => {
      if (location.hash !== hash) return;
      const a = document.activeElement;
      const typing = a && /^(INPUT|SELECT|TEXTAREA)$/.test(a.tagName);
      if (document.visibilityState !== 'visible' || typing || document.querySelector('dialog[open]')) return scheduleLive(hash);
      const y = window.scrollY;
      route().then(() => window.scrollTo(0, y));
    }, 60000);
  }
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && route._t && state.me) {
      const key = (location.hash.replace(/^#\/?/, '').split('?')[0]);
      if (ROUTES[key] && ROUTES[key].live) { const y = window.scrollY; route().then(() => window.scrollTo(0, y)); }
    }
  });

  // ---------------------------------------------------------------- auth
  async function loadSession() {
    const { data } = await sb.auth.getSession();
    state.user = data.session ? data.session.user : null;
    state.me = null;
    if (state.user) {
      const rows = await q(sb.from('staff').select('*').eq('auth_user_id', state.user.id).eq('is_active', true).limit(1));
      state.me = rows[0] || null;
    }
    const bar = document.getElementById('bar');
    bar.hidden = !state.user;
    document.getElementById('who-name').textContent = state.me ? state.me.full_name : (state.user ? state.user.email : '');
  }

  function viewLogin(mode) {
    const signup = mode === 'signup';
    setView(`
      <div class="auth">
        <div class="panel">
          <img src="assets/moph.png" alt="ตรากระทรวงสาธารณสุข" width="72" height="72">
          <h1>ระบบลงเวลาปฏิบัติราชการ</h1>
          <p class="muted" style="text-align:center">โรงพยาบาลส่งเสริมสุขภาพตำบลสองคอน</p>
          <form id="auth-form" novalidate>
            <label class="f">อีเมล<input type="email" name="email" autocomplete="email" required></label>
            <label class="f">รหัสผ่าน<input type="password" name="password" autocomplete="${signup ? 'new-password' : 'current-password'}" minlength="8" required></label>
            <p class="err" id="auth-err" role="alert"></p>
            <button class="btn" type="submit">${signup ? 'สมัครบัญชี' : 'เข้าสู่ระบบ'}</button>
          </form>
          <p style="margin-top:14px;text-align:center">
            ${signup ? 'มีบัญชีแล้ว?' : 'ยังไม่มีบัญชี?'}
            <button type="button" class="link" id="auth-switch">${signup ? 'เข้าสู่ระบบ' : 'สมัครบัญชีใหม่'}</button>
          </p>
        </div>
      </div>`);
    document.getElementById('auth-switch').onclick = () => viewLogin(signup ? 'login' : 'signup');
    document.getElementById('auth-form').onsubmit = async (ev) => {
      ev.preventDefault();
      const f = ev.target, err = document.getElementById('auth-err'), btn = f.querySelector('button');
      const email = f.email.value.trim(), password = f.password.value;
      err.textContent = '';
      if (!email || password.length < 8) { err.textContent = 'กรอกอีเมล และรหัสผ่านอย่างน้อย 8 ตัวอักษร'; return; }
      busy(btn, true);
      try {
        if (signup) {
          const { data, error } = await sb.auth.signUp({ email, password, options: { emailRedirectTo: location.origin + location.pathname } });
          if (error) throw error;
          if (!data.session) {
            err.style.color = 'var(--green-dark)';
            err.textContent = 'สมัครแล้ว เปิดอีเมลเพื่อยืนยันบัญชี จากนั้นกลับมาเข้าสู่ระบบ';
            return;
          }
        } else {
          const { error } = await sb.auth.signInWithPassword({ email, password });
          if (error) throw error;
        }
      } catch (e) {
        err.textContent = /Invalid login/i.test(e.message) ? 'อีเมลหรือรหัสผ่านไม่ถูกต้อง' : e.message;
      } finally { busy(btn, false); }
    };
  }

  function viewPending() {
    renderNav('');
    document.getElementById('nav').innerHTML = '';
    setView(`
      <div class="auth"><div class="panel">
        <h1>รอผู้ดูแลระบบผูกบัญชี</h1>
        <p>บัญชี <b>${esc(state.user.email)}</b> ยังไม่ได้ผูกกับรายชื่อเจ้าหน้าที่</p>
        <p class="muted">แจ้งผู้ดูแลระบบให้ผูกบัญชีนี้ในหน้า "เจ้าหน้าที่" แล้วกดปุ่มด้านล่าง</p>
        <button class="btn" id="recheck" type="button">ตรวจอีกครั้ง</button>
      </div></div>`);
    document.getElementById('recheck').onclick = async () => { await loadSession(); route(); };
  }

  // ---------------------------------------------------------------- ใบบัญชีลงเวลา
  async function viewSheet() {
    const params = new URLSearchParams(location.hash.split('?')[1] || '');
    const day = params.get('d') || todayISO();
    const [rows, sumRows, settings, sync, mob] = await Promise.all([
      q(sb.rpc('daily_sheet', { p_day: day })),
      q(sb.rpc('daily_summary', { p_day: day })),
      q(sb.from('settings').select('*').eq('id', 1).single()),
      q(sb.from('device_sync').select('*').eq('id', 1).maybeSingle()),
      q(sb.rpc('mobile_logs', { p_day: day })).catch(() => [])
    ]);
    state.settings = settings;
    const s = sumRows[0] || {};
    const away = rows.filter((r) => /นอกพื้นที่/.test(r.remark || '')).length;
    const minRows = 22;
    const body = rows.map((r, i) => `
      <tr>
        <td>${i + 1}</td>
        <td class="name">${esc(r.full_name)}</td>
        <td>${esc(METHOD[r.method_in] || '')}</td>
        <td class="${r.is_late ? 'is-late' : ''}">${hhmm(r.time_in)}</td>
        <td>${esc(METHOD[r.method_out] || '')}</td>
        <td>${hhmm(r.time_out)}</td>
        <td class="note">${esc([r.is_late ? 'มาสาย' : '', r.remark].filter(Boolean).join(' · '))}</td>
      </tr>`).join('') +
      Array.from({ length: Math.max(0, minRows - rows.length) }, (_, i) =>
        `<tr class="blank"><td>${rows.length + i + 1}</td><td></td><td></td><td></td><td></td><td></td><td></td></tr>`).join('');

    setView(`
      <div class="head no-print">
        <div><h1>ใบบัญชีลงเวลา</h1><p class="muted">${thaiDate(day, { weekday: 'long' })}</p></div>
        <div class="row">
          <label class="f">วันที่<input type="date" id="day" value="${day}"></label>
          <button class="btn quiet" type="button" id="prev" aria-label="วันก่อนหน้า">‹</button>
          <button class="btn quiet" type="button" id="next" aria-label="วันถัดไป">›</button>
          <button class="btn" type="button" id="print">พิมพ์ใบบัญชี</button>
        </div>
      </div>
      <div class="tiles no-print">
        <div class="tile ok"><b>${s.present ?? 0}</b><span>มาปฏิบัติราชการ</span></div>
        <div class="tile late"><b>${s.late ?? 0}</b><span>มาสาย</span></div>
        <div class="tile away"><b>${(s.official ?? 0)}</b><span>ไปราชการ</span></div>
        <div class="tile"><b>${s.absent ?? 0}</b><span>ไม่มา / ลา</span></div>
        <div class="tile away"><b>${away}</b><span>ลงเวลานอกพื้นที่</span></div>
      </div>
      <p class="muted no-print" style="font-size:14px">ข้อมูลจากเครื่องสแกนเข้าระบบล่าสุด ${thaiDateTime(sync && sync.last_sync_at)} · นับสายเมื่อมาหลัง ${hhmm(settings.work_start)} เกิน ${settings.late_grace_min} นาที · หน้านี้อัปเดตเองทุก 1 นาที</p>

      <article class="sheet" aria-label="ใบบัญชีลงเวลาสำหรับพิมพ์">
        <div class="sheet-head">
          <h2>บัญชีลงเวลาการปฏิบัติราชการของข้าราชการ</h2>
          <div>${thaiDate(day, { weekday: 'long' })}</div>
          <div>${esc(settings.site_name)} อำเภอ${esc(settings.district)} จังหวัด${esc(settings.province)}</div>
        </div>
        <table class="ledger">
          <thead><tr>
            <th style="width:40px">ลำดับที่</th><th>ชื่อ-ชื่อสกุล</th>
            <th style="width:72px">ช่องทาง</th><th style="width:56px">เวลามา</th>
            <th style="width:72px">ช่องทาง</th><th style="width:56px">เวลากลับ</th>
            <th style="width:150px">หมายเหตุ</th>
          </tr></thead>
          <tbody>${body}</tbody>
        </table>
        <div class="sum">
          ${[['ข้าราชการทั้งหมด', s.total], ['อัตราว่าง', s.vacancies], ['ยืมตัวมาช่วยราชการ', s.seconded], ['มาปฏิบัติราชการ', s.present], ['ไม่มา', s.absent], ['มาสาย', s.late], ['ไปราชการ', s.official]]
            .map(([l, v]) => `<div><span>${l}</span><span class="v">${v ?? 0}</span><span>คน</span></div>`).join('')}
        </div>
        <div class="sign">ผู้ตรวจ ..................................................<br>(หัวหน้าหน่วยงานผู้รับผิดชอบงานการเจ้าหน้าที่)</div>
        <div class="sheet-foot">ช่องทาง: ใบหน้า / ลายนิ้วมือ / รหัส / บัตร (เครื่องสแกน) · มือถือ · พิมพ์จากระบบเมื่อ ${thaiDateTime(new Date().toISOString())}</div>
      </article>
      ${mob.length ? `
      <div class="panel no-print" style="margin-top:18px">
        <h2>ลงเวลาผ่านมือถือ (${mob.length})</h2>
        <div class="mob-grid">${mob.map((m, i) => `
          <figure class="mob">
            <img data-selfie="${esc(m.selfie_path || '')}" alt="รูปยืนยันของ ${esc(m.full_name)}" width="120" height="90">
            <figcaption><b>${esc(m.full_name)}</b><br>
              ${new Date(m.log_time).toLocaleTimeString('th-TH', { timeZone: 'Asia/Bangkok', hour: '2-digit', minute: '2-digit', hour12: false })}
              ${m.direction === 'out' ? 'กลับ' : 'มา'} ·
              ${m.in_area ? `ในพื้นที่ (${m.distance_m} ม.)` : `<span class="tag away">นอกพื้นที่ ${m.distance_m >= 1000 ? (m.distance_m / 1000).toFixed(1) + ' กม.' : m.distance_m + ' ม.'}</span> ${esc(m.reason || '')}`}
              ${m.face_score != null ? `<br><span class="muted">ความต่างใบหน้า ${Number(m.face_score).toFixed(2)}</span>` : ''}
            </figcaption>
          </figure>`).join('')}</div>
      </div>` : ''}`);
    const imgs = [...$app.querySelectorAll('img[data-selfie]')].filter((im) => im.dataset.selfie);
    if (imgs.length) {
      sb.storage.from('selfies').createSignedUrls(imgs.map((im) => im.dataset.selfie), 600).then(({ data }) => {
        (data || []).forEach((d, i) => { if (d.signedUrl) imgs[i].src = d.signedUrl; });
      });
    }

    const go = (d) => { location.hash = '#/sheet?d=' + d; };
    const shift = (n) => { const t = new Date(day + 'T12:00:00Z'); t.setUTCDate(t.getUTCDate() + n); go(t.toISOString().slice(0, 10)); };
    document.getElementById('day').onchange = (e) => e.target.value && go(e.target.value);
    document.getElementById('prev').onclick = () => shift(-1);
    document.getElementById('next').onclick = () => shift(1);
    document.getElementById('print').onclick = () => window.print();
  }

  // ---------------------------------------------------------------- เจ้าหน้าที่
  async function viewStaff() {
    const [staff, users, emails, unmatched, people, settings, counts, faces] = await Promise.all([
      q(sb.from('staff').select('*').order('sort_order').order('full_name')),
      q(sb.rpc('list_unlinked_users')),
      q(sb.rpc('staff_emails')),
      q(sb.from('hip_unmatched_summary').select('*').order('enroll_number')),
      q(sb.from('hip_people').select('enroll_number')),
      q(sb.from('settings').select('positions').eq('id', 1).single()),
      q(sb.rpc('staff_scan_counts')),
      q(sb.rpc('face_status')).catch(() => [])
    ]);
    const hasFace = new Set(faces.map((f) => f.staff_id));
    const emailOf = Object.fromEntries(emails.map((e) => [e.staff_id, e.email]));
    const scansOf = Object.fromEntries(counts.map((c) => [c.staff_id, Number(c.scans)]));
    const positions = settings.positions || [];
    const active = staff.filter((s) => s.is_active);
    const inactive = staff.filter((s) => !s.is_active);
    const known = new Set(staff.map((s) => s.hip_user_id).filter(Boolean));
    const newPeople = people.filter((p) => !known.has(p.enroll_number)).length;
    const ro = !isAdmin();
    const opt = (obj, val) => Object.entries(obj).map(([k, l]) => `<option value="${k}"${k === val ? ' selected' : ''}>${l}</option>`).join('');

    const rowHtml = (s, i) => `
      <tr>
        <td>${i + 1}</td>
        <td><b>${esc(s.full_name)}</b>${s.on_sheet ? '' : ' <span class="tag none">ไม่แสดงในใบบัญชี</span>'}${hasFace.has(s.id) ? ' <span class="tag" title="ลงทะเบียนใบหน้าสำหรับลงเวลาผ่านมือถือแล้ว">ใบหน้า ✓</span>' : ''}</td>
        <td>${esc(s.position || '—')}</td>
        <td>${esc(TYPE[s.staff_type] || '')}</td>
        <td>${esc(s.emp_code || '—')}</td>
        <td>${s.hip_user_id ? esc(s.hip_user_id) : '<span class="muted">—</span>'}</td>
        <td>${s.role === 'staff' ? 'เจ้าหน้าที่' : `<span class="tag${s.role === 'viewer' ? ' away' : ''}">${s.role === 'admin' ? 'ผู้ดูแล' : 'ผู้บริหาร'}</span>`}</td>
        <td>${emailOf[s.id] ? esc(emailOf[s.id]) : '<span class="muted">—</span>'}</td>
        <td class="actions">${ro ? '' : `
          <button class="btn quiet" type="button" data-edit="${s.id}">แก้ไข</button>
          ${s.id === state.me.id ? '' : `<button class="btn danger" type="button" data-off="${s.id}">ลบ</button>`}`}
        </td>
      </tr>`;

    setView(`
      <div class="head"><div><h1>เจ้าหน้าที่</h1><p class="muted">${active.length} คนที่ใช้งานอยู่</p></div>
        ${ro ? '<p class="muted">ดูอย่างเดียว</p>' : `<div class="row">
          <button class="btn" type="button" id="add">เพิ่มเจ้าหน้าที่</button>
        </div>`}
      </div>
      ${unmatched.length && !ro ? `
      <div class="panel" style="border-color:#EAD3A8;background:#FFF8EC">
        <h2>รายการสแกนที่ยังไม่รู้ว่าเป็นใคร</h2>
        <p class="muted">กด "แก้ไข" ที่เจ้าหน้าที่คนนั้น ใส่เลขในช่อง "เลขในเครื่องสแกน" แล้วกด "ย้ายรายการค้าง"</p>
        <div class="tbl-wrap"><table class="data"><thead><tr><th>เลขในเครื่องสแกน</th><th>ชื่อในเครื่อง</th><th>จำนวน</th><th>ล่าสุด</th></tr></thead><tbody>
          ${unmatched.map((u) => `<tr><td>${esc(u.enroll_number)}</td><td>${esc(u.hip_name || '—')}</td><td>${u.scans}</td><td>${thaiDateTime(u.last_scan)}</td></tr>`).join('')}
        </tbody></table></div>
        <button class="btn quiet" type="button" id="rematch" style="margin-top:10px">ย้ายรายการค้าง</button>
      </div>` : ''}
      <div class="panel tbl-wrap">
        <table class="data">
          <thead><tr><th>ลำดับ</th><th>ชื่อ-สกุล</th><th>ตำแหน่ง</th><th>ประเภท</th><th>รหัส</th><th title="เลขของคนนี้ในเครื่องสแกน ใช้จับคู่เวลาที่สแกน">เลขในเครื่องสแกน</th><th>สิทธิ์</th><th>บัญชีล็อกอิน</th><th></th></tr></thead>
          <tbody>${active.map(rowHtml).join('') || '<tr><td colspan="9" class="muted">ยังไม่มีเจ้าหน้าที่ กด "เพิ่มเจ้าหน้าที่"</td></tr>'}</tbody>
        </table>
      </div>
      ${inactive.length ? `
      <details class="panel">
        <summary><b>เลิกใช้งานแล้ว (${inactive.length})</b> <span class="muted">— ไม่แสดงในใบบัญชี แต่ประวัติลงเวลายังอยู่</span></summary>
        <div class="tbl-wrap" style="margin-top:10px"><table class="data"><tbody>
          ${inactive.map((s) => `<tr><td>${esc(s.full_name)}</td><td>${esc(s.position || '')}</td><td>${scansOf[s.id] || 0} รายการสแกน</td>
            <td class="actions">${ro ? '' : `<button class="btn quiet" type="button" data-on="${s.id}">ใช้งานอีกครั้ง</button>
            ${scansOf[s.id] ? '' : `<button class="btn danger" type="button" data-purge="${s.id}">ลบถาวร</button>`}`}</td></tr>`).join('')}
        </tbody></table></div>
      </details>` : ''}

      <dialog id="staff-dlg" aria-labelledby="dlg-title">
        <form id="staff-form" method="dialog">
          <h2 id="dlg-title">แก้ไขเจ้าหน้าที่</h2>
          <div class="grid2">
            <label class="f" style="grid-column:1/-1">ชื่อ-สกุล<input name="full_name" required></label>
            <label class="f" style="grid-column:1/-1">ตำแหน่ง <span class="muted" style="font-size:13px">เลือกจากรายการ หรือพิมพ์ตำแหน่งใหม่</span>
              <input name="position" list="pos-list" autocomplete="off" placeholder="เลือกหรือพิมพ์ตำแหน่ง">
              <datalist id="pos-list">${positions.map((p) => `<option value="${esc(p)}"></option>`).join('')}</datalist>
            </label>
            <label class="f">ประเภท<select name="staff_type">${opt(TYPE, 'civil')}</select></label>
            <label class="f">รหัสพนักงาน<input name="emp_code" inputmode="numeric" placeholder="เช่น 01"></label>
            <label class="f">เลขในเครื่องสแกน<input name="hip_user_id" inputmode="numeric" placeholder="เลขที่ใช้ในเครื่อง เช่น 1"></label>
            <label class="f">ลำดับในใบบัญชี<input name="sort_order" type="number" min="0"></label>
            <label class="f">สิทธิ์<select name="role">${opt(ROLE, 'staff')}</select></label>
            <label class="f" style="grid-column:1/-1">บัญชีล็อกอิน<select name="link"></select></label>
            <label class="check" style="grid-column:1/-1"><input type="checkbox" name="on_sheet"> แสดงในใบบัญชีลงเวลา</label>
          </div>
          <div id="face-row" class="row" style="margin-top:6px" hidden>
            <span class="muted" style="font-size:14px">ลงทะเบียนใบหน้าแล้ว (ลงเวลาผ่านมือถือ)</span>
            <button class="btn danger" type="button" id="face-reset">รีเซ็ตใบหน้า</button>
          </div>
          <p class="err" id="dlg-err" role="alert"></p>
          <div class="row" style="justify-content:flex-end;margin-top:8px">
            <button class="btn quiet" type="button" id="dlg-cancel">ยกเลิก</button>
            <button class="btn" type="submit" id="dlg-save">บันทึก</button>
          </div>
        </form>
      </dialog>`);

    if (ro) return;
    // ---- ฟอร์มเพิ่ม/แก้ไข
    const dlg = document.getElementById('staff-dlg'), f = document.getElementById('staff-form');
    let editing = null;
    function openForm(s) {
      editing = s || null;
      document.getElementById('dlg-title').textContent = s ? 'แก้ไขเจ้าหน้าที่' : 'เพิ่มเจ้าหน้าที่';
      document.getElementById('dlg-err').textContent = '';
      const maxOrder = staff.reduce((m, x) => Math.max(m, x.sort_order || 0), 0);
      f.full_name.value = s ? s.full_name : '';
      f.position.value = s ? (s.position || '') : '';
      f.staff_type.value = s ? s.staff_type : 'civil';
      f.hip_user_id.value = s ? (s.hip_user_id || '') : '';
      f.emp_code.value = s ? (s.emp_code || '') : '';
      f.sort_order.value = s ? s.sort_order : maxOrder + 1;
      f.role.value = s ? s.role : 'staff';
      f.on_sheet.checked = s ? s.on_sheet : true;
      const cur = s && emailOf[s.id];
      f.link.innerHTML = (cur ? `<option value="">${esc(cur)} (ผูกอยู่)</option>` : '<option value="">— ไม่ผูกบัญชี —</option>') +
        users.map((u) => `<option value="${u.user_id}">${esc(u.email)}</option>`).join('');
      f.link.disabled = !users.length;
      document.getElementById('face-row').hidden = !(s && hasFace.has(s.id));
      dlg.showModal();
      f.full_name.focus();
    }
    document.getElementById('dlg-cancel').onclick = () => dlg.close();
    document.getElementById('face-reset').onclick = async () => {
      if (!editing || !confirm(`รีเซ็ตใบหน้าของ "${editing.full_name}"?\nเจ้าหน้าที่ต้องลงทะเบียนใบหน้าใหม่ก่อนลงเวลาผ่านมือถือครั้งถัดไป`)) return;
      try { await q(sb.rpc('reset_face', { p_staff_id: editing.id })); dlg.close(); toast('รีเซ็ตใบหน้าแล้ว'); route(); } catch (e) { fail(e); }
    };
    f.onsubmit = async (ev) => {
      ev.preventDefault();
      const err = document.getElementById('dlg-err'), btn = document.getElementById('dlg-save');
      const patch = {
        full_name: f.full_name.value.trim(),
        position: f.position.value.trim() || null,
        staff_type: f.staff_type.value,
        hip_user_id: f.hip_user_id.value.trim() || null,
        emp_code: f.emp_code.value.trim() || null,
        sort_order: Number(f.sort_order.value) || 0,
        role: f.role.value,
        on_sheet: f.on_sheet.checked
      };
      if (!patch.full_name) { err.textContent = 'กรอกชื่อ-สกุล'; return; }
      if (patch.hip_user_id && staff.some((x) => x.hip_user_id === patch.hip_user_id && (!editing || x.id !== editing.id))) {
        err.textContent = 'เลขในเครื่องสแกนนี้ใช้กับเจ้าหน้าที่คนอื่นแล้ว'; return;
      }
      if (patch.emp_code && staff.some((x) => x.emp_code === patch.emp_code && (!editing || x.id !== editing.id))) {
        err.textContent = 'รหัสพนักงานนี้ใช้กับเจ้าหน้าที่คนอื่นแล้ว'; return;
      }
      if (editing && editing.id === state.me.id && patch.role !== 'admin' &&
          !confirm('ถ้าเปลี่ยนสิทธิ์ของตัวเองเป็น "' + ROLE[patch.role] + '" จะแก้ไขข้อมูลไม่ได้อีก ยืนยันไหม')) return;
      busy(btn, true);
      try {
        let id = editing && editing.id;
        if (id) await q(sb.from('staff').update(patch).eq('id', id));
        else id = (await q(sb.from('staff').insert(patch).select('id').single())).id;
        if (f.link.value) await q(sb.rpc('link_staff_user', { p_staff_id: id, p_user_id: f.link.value }));
        // ตำแหน่งใหม่ที่พิมพ์เอง → เพิ่มเข้ารายการ
        if (patch.position && !positions.includes(patch.position)) {
          await q(sb.from('settings').update({ positions: positions.concat(patch.position) }).eq('id', 1));
        }
        dlg.close();
        toast(editing ? 'บันทึกการแก้ไขแล้ว' : 'เพิ่มเจ้าหน้าที่แล้ว');
        await loadSession(); route();
      } catch (e) { err.textContent = e.message; busy(btn, false); }
    };

    document.getElementById('add').onclick = () => openForm(null);
    $app.querySelectorAll('[data-edit]').forEach((b) => b.onclick = () => openForm(staff.find((s) => s.id === b.dataset.edit)));

    // ---- ลบ = ย้ายไปเลิกใช้งาน (เก็บประวัติ)
    $app.querySelectorAll('[data-off]').forEach((b) => b.onclick = async () => {
      const s = staff.find((x) => x.id === b.dataset.off);
      if (!confirm(`ลบ "${s.full_name}" ออกจากรายชื่อ?\n\nจะไม่แสดงในใบบัญชีอีก แต่ประวัติลงเวลาเดิมยังอยู่ และกู้คืนได้จากส่วน "เลิกใช้งานแล้ว"`)) return;
      try { await q(sb.from('staff').update({ is_active: false }).eq('id', s.id)); toast('ย้ายไปเลิกใช้งานแล้ว'); route(); } catch (e) { fail(e); }
    });
    $app.querySelectorAll('[data-on]').forEach((b) => b.onclick = async () => {
      try { await q(sb.from('staff').update({ is_active: true }).eq('id', b.dataset.on)); toast('กลับมาใช้งานแล้ว'); route(); } catch (e) { fail(e); }
    });
    $app.querySelectorAll('[data-purge]').forEach((b) => b.onclick = async () => {
      const s = staff.find((x) => x.id === b.dataset.purge);
      if (!confirm(`ลบ "${s.full_name}" ถาวร? ทำย้อนกลับไม่ได้`)) return;
      try { await q(sb.rpc('delete_staff_if_unused', { p_staff_id: s.id })); toast('ลบถาวรแล้ว'); route(); } catch (e) { fail(e); }
    });

    const imp = document.getElementById('import');
    if (imp) imp.onclick = async () => {
      busy(imp, true);
      try { const r = await q(sb.rpc('import_hip_people')); toast(`เพิ่มเจ้าหน้าที่ ${r.new_staff} คน · ย้ายรายการสแกน ${r.moved_scans} รายการ`); route(); }
      catch (e) { fail(e); busy(imp, false); }
    };
    const rm = document.getElementById('rematch');
    if (rm) rm.onclick = async () => {
      busy(rm, true);
      try { const n = await q(sb.rpc('hip_rematch')); toast(`ย้ายรายการค้าง ${n} รายการ`); route(); }
      catch (e) { fail(e); busy(rm, false); }
    };
  }

  // ---------------------------------------------------------------- สรุปรายเดือน
  async function viewMonthly() {
    const params = new URLSearchParams(location.hash.split('?')[1] || '');
    const month = params.get('m') || todayISO().slice(0, 7);
    const first = month + '-01';
    const rows = await q(sb.rpc('monthly_summary', { p_month: first }));
    const wd = rows[0] ? rows[0].workdays : 0;
    const monthTH = new Date(first + 'T00:00:00+07:00').toLocaleDateString('th-TH', { month: 'long', year: 'numeric', timeZone: 'Asia/Bangkok' });
    const tot = rows.reduce((a, r) => ({ late: a.late + r.late, leave: a.leave + r.leave, absent: a.absent + r.absent, official: a.official + r.official }), { late: 0, leave: 0, absent: 0, official: 0 });
    setView(`
      <div class="head"><div><h1>สรุปรายเดือน</h1><p class="muted">${monthTH} · วันทำการ ${wd} วัน (นับถึงวันนี้ ไม่รวมวันหยุด)</p></div>
        <div class="row">
          <label class="f">เดือน<input type="month" id="month" value="${month}"></label>
          <button class="btn" type="button" id="xlsx">ดาวน์โหลด Excel</button>
        </div>
      </div>
      <div class="tiles">
        <div class="tile late"><b>${tot.late}</b><span>ครั้งที่มาสาย</span></div>
        <div class="tile away"><b>${tot.official}</b><span>วันไปราชการ</span></div>
        <div class="tile"><b>${tot.leave}</b><span>วันลา</span></div>
        <div class="tile"><b>${tot.absent}</b><span>วันไม่ได้ลงเวลา</span></div>
      </div>
      <div class="panel tbl-wrap">
        <table class="data">
          <thead><tr><th>ลำดับ</th><th>ชื่อ-สกุล</th><th>ตำแหน่ง</th><th style="text-align:right">มา</th><th style="text-align:right">สาย</th><th style="text-align:right">สายรวม (นาที)</th><th style="text-align:right">ไปราชการ</th><th style="text-align:right">ลา</th><th style="text-align:right">ไม่ได้ลงเวลา</th><th style="text-align:right">ไม่สแกนกลับ</th><th style="text-align:right">นอกพื้นที่</th></tr></thead>
          <tbody>${rows.map((r, i) => `<tr>
            <td>${i + 1}</td><td><b>${esc(r.full_name)}</b></td><td>${esc(r.staff_position || '')}</td>
            <td style="text-align:right">${r.present}</td>
            <td style="text-align:right">${r.late ? `<span class="tag late">${r.late}</span>` : 0}</td>
            <td style="text-align:right">${r.late_minutes}</td>
            <td style="text-align:right">${r.official}</td><td style="text-align:right">${r.leave}</td>
            <td style="text-align:right">${r.absent}</td><td style="text-align:right">${r.no_out}</td><td style="text-align:right">${r.away}</td>
          </tr>`).join('') || '<tr><td colspan="11" class="muted">ไม่มีข้อมูลในเดือนนี้</td></tr>'}</tbody>
        </table>
      </div>
      <p class="muted" style="font-size:14px">"ไม่ได้ลงเวลา" คือวันทำการที่ไม่มีการสแกนและไม่ได้บันทึกลาหรือไปราชการไว้ ถ้ามีวันลาที่ยังไม่ได้บันทึก ให้เพิ่มในเมนู "ลา / ไปราชการ"</p>`);

    document.getElementById('month').onchange = (e) => { if (e.target.value) location.hash = '#/monthly?m=' + e.target.value; };
    document.getElementById('xlsx').onclick = async (ev) => {
      const b = ev.target; busy(b, true);
      try {
        await loadScript('https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js');
        const detail = await q(sb.rpc('monthly_detail', { p_month: first }));
        const sum = rows.map((r, i) => ({
          'ลำดับ': i + 1, 'ชื่อ-สกุล': r.full_name, 'ตำแหน่ง': r.staff_position || '', 'ประเภท': TYPE[r.staff_type] || '',
          'วันทำการ': r.workdays, 'มา': r.present, 'สาย (ครั้ง)': r.late, 'สายรวม (นาที)': r.late_minutes,
          'ไปราชการ': r.official, 'ลา': r.leave, 'ไม่ได้ลงเวลา': r.absent, 'ไม่สแกนกลับ': r.no_out, 'นอกพื้นที่': r.away
        }));
        const det = detail.map((d) => ({
          'วันที่': thaiDate(d.day, { weekday: 'short' }), 'ชื่อ-สกุล': d.full_name,
          'เวลามา': hhmm(d.time_in), 'ช่องทาง (มา)': METHOD[d.method_in] || '',
          'เวลากลับ': hhmm(d.time_out), 'ช่องทาง (กลับ)': METHOD[d.method_out] || '',
          'สาย': d.is_late ? 'สาย' : '', 'สถานะ': { present: 'มา', official: 'ไปราชการ', absent: 'ไม่มา/ลา' }[d.status] || d.status,
          'หมายเหตุ': d.remark || ''
        }));
        const wb = XLSX.utils.book_new();
        const ws1 = XLSX.utils.json_to_sheet(sum); ws1['!cols'] = [{ wch: 6 }, { wch: 28 }, { wch: 24 }, { wch: 20 }].concat(Array(9).fill({ wch: 12 }));
        const ws2 = XLSX.utils.json_to_sheet(det); ws2['!cols'] = [{ wch: 18 }, { wch: 28 }, { wch: 9 }, { wch: 12 }, { wch: 9 }, { wch: 12 }, { wch: 6 }, { wch: 12 }, { wch: 36 }];
        XLSX.utils.book_append_sheet(wb, ws1, 'สรุปรายเดือน');
        XLSX.utils.book_append_sheet(wb, ws2, 'รายวัน');
        XLSX.writeFile(wb, `songkon-attendance-${month}.xlsx`);
        toast('ดาวน์โหลด Excel แล้ว');
      } catch (e) { fail(e); } finally { busy(b, false); }
    };
  }

  function loadScript(src) {
    if (loadScript.done && loadScript.done[src]) return Promise.resolve();
    return new Promise((res, rej) => {
      const el = document.createElement('script'); el.src = src;
      el.onload = () => { (loadScript.done = loadScript.done || {})[src] = true; res(); };
      el.onerror = () => rej(new Error('โหลดไลบรารี Excel ไม่สำเร็จ ตรวจการเชื่อมต่ออินเทอร์เน็ต'));
      document.head.appendChild(el);
    });
  }

  // ---------------------------------------------------------------- ลา / ไปราชการ
  async function viewLeave() {
    const params = new URLSearchParams(location.hash.split('?')[1] || '');
    const month = params.get('m') || todayISO().slice(0, 7);
    const start = month + '-01';
    const endD = new Date(start + 'T12:00:00Z'); endD.setUTCMonth(endD.getUTCMonth() + 1);
    const end = endD.toISOString().slice(0, 10);
    const [staff, leaves] = await Promise.all([
      q(sb.from('staff').select('id, full_name').eq('is_active', true).eq('on_sheet', true).order('sort_order')),
      q(sb.from('leave_records').select('id, day, kind, note, staff_id').gte('day', start).lt('day', end).order('day'))
    ]);
    const nameOf = Object.fromEntries(staff.map((s) => [s.id, s.full_name]));
    const ro = !isAdmin();
    setView(`
      <div class="head"><div><h1>ลา / ไปราชการ</h1><p class="muted">บันทึกวันที่เจ้าหน้าที่ลาหรือไปราชการ เพื่อให้ใบบัญชีนับถูกช่อง</p></div></div>
      ${ro ? '' : `<form class="panel" id="lv-form">
        <h2>บันทึกใหม่</h2>
        <div class="grid2">
          <label class="f">เจ้าหน้าที่<select name="staff_id" required>${staff.map((s) => `<option value="${s.id}">${esc(s.full_name)}</option>`).join('')}</select></label>
          <label class="f">ตั้งแต่วันที่<input type="date" name="from" value="${todayISO()}" required></label>
          <label class="f">ถึงวันที่<input type="date" name="to" value="${todayISO()}" required></label>
          <label class="f">ประเภท<select name="kind">${Object.entries(LEAVE).map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
          <label class="f" style="grid-column:1/-1">รายละเอียด (ไม่บังคับ)<input name="note" placeholder="เช่น ลาป่วย, ประชุมที่ สสอ.โพธิ์ไทร"></label>
        </div>
        <button class="btn" type="submit" style="margin-top:12px">บันทึก</button>
      </form>`}
      <div class="panel">
        <div class="head" style="margin-bottom:8px"><h2 style="margin:0">รายการเดือนนี้</h2>
          <label class="f">เดือน<input type="month" id="month" value="${month}"></label></div>
        <div class="tbl-wrap"><table class="data"><thead><tr><th>วันที่</th><th>เจ้าหน้าที่</th><th>ประเภท</th><th>รายละเอียด</th><th></th></tr></thead><tbody>
          ${leaves.map((l) => `<tr><td>${thaiDate(l.day, { weekday: 'short' })}</td><td>${esc(nameOf[l.staff_id] || '—')}</td>
            <td><span class="tag ${l.kind === 'official' ? 'away' : 'none'}">${LEAVE[l.kind]}</span></td><td>${esc(l.note)}</td>
            <td>${ro ? '' : `<button class="btn danger" type="button" data-del="${l.id}">ลบ</button>`}</td></tr>`).join('') ||
            '<tr><td colspan="5" class="muted">ยังไม่มีรายการในเดือนนี้</td></tr>'}
        </tbody></table></div>
      </div>`);

    document.getElementById('month').onchange = (e) => { if (e.target.value) location.hash = '#/leave?m=' + e.target.value; };
    if (ro) return;
    document.getElementById('lv-form').onsubmit = async (ev) => {
      ev.preventDefault();
      const f = ev.target, btn = f.querySelector('button[type=submit]');
      if (!f.staff_id.value) return toast('ยังไม่มีรายชื่อเจ้าหน้าที่');
      if (f.to.value < f.from.value) return toast('วันที่สิ้นสุดต้องไม่ก่อนวันเริ่ม');
      const rows = [];
      for (let d = new Date(f.from.value + 'T12:00:00Z'); d.toISOString().slice(0, 10) <= f.to.value; d.setUTCDate(d.getUTCDate() + 1)) {
        rows.push({ staff_id: f.staff_id.value, day: d.toISOString().slice(0, 10), kind: f.kind.value, note: f.note.value.trim() || null, created_by: state.me.id });
        if (rows.length > 62) break;
      }
      busy(btn, true);
      try { await q(sb.from('leave_records').upsert(rows, { onConflict: 'staff_id,day' })); toast(`บันทึกแล้ว ${rows.length} วัน`); route(); }
      catch (e) { fail(e); busy(btn, false); }
    };
    $app.querySelectorAll('[data-del]').forEach((b) => b.onclick = async () => {
      if (!confirm('ลบรายการนี้?')) return;
      try { await q(sb.from('leave_records').delete().eq('id', b.dataset.del)); toast('ลบแล้ว'); route(); } catch (e) { fail(e); }
    });
  }

  // ---------------------------------------------------------------- ตั้งค่า
  async function viewSettings() {
    const [s, sync] = await Promise.all([
      q(sb.from('settings').select('*').eq('id', 1).single()),
      q(sb.from('device_sync').select('*').eq('id', 1).maybeSingle())
    ]);
    const field = (name, label, type, extra) => `<label class="f">${label}<input type="${type}" name="${name}" value="${esc(type === 'time' ? hhmm(s[name]) : s[name])}" ${extra || ''}></label>`;
    setView(`
      <div class="head"><div><h1>ตั้งค่า</h1></div></div>
      <form class="panel" id="st-form">
        <h2>เวลาปฏิบัติราชการ</h2>
        <div class="grid2">
          ${field('work_start', 'เวลาเข้างาน', 'time')}
          ${field('late_grace_min', 'นับสายเมื่อเกิน (นาที)', 'number', 'min="0" max="120"')}
          ${field('work_end', 'เวลาเลิกงาน', 'time')}
          ${field('vacancies', 'อัตราว่าง (คน)', 'number', 'min="0"')}
        </div>
        <h2 style="margin-top:20px">พื้นที่ลงเวลาด้วยมือถือ</h2>
        <div class="grid2">
          ${field('site_lat', 'ละติจูด', 'number', 'step="0.000001"')}
          ${field('site_lng', 'ลองจิจูด', 'number', 'step="0.000001"')}
          ${field('radius_m', 'รัศมี (เมตร)', 'number', 'min="20" max="5000"')}
        </div>
        <h2 style="margin-top:20px">แจ้งเตือน Telegram</h2>
        <label class="check"><input type="checkbox" name="telegram_notify" ${s.telegram_notify ? 'checked' : ''}> เปิดการแจ้งเตือน (ลงเวลาใหม่ทุก 15 นาที · มาสาย · สรุปรายวัน)</label>
        <div class="grid2">
          ${field('telegram_chat_id', 'Chat ID ของกลุ่ม (ขึ้นต้น -100)', 'text')}
          ${field('telegram_topic_id', 'เลขหัวข้อ (Topic)', 'text')}
        </div>
        <h2 style="margin-top:20px">นอกเวลาราชการ</h2>
        <div class="grid2">
          ${field('ot_start', 'เริ่ม', 'time')}
          ${field('ot_end', 'เลิก', 'time')}
          ${field('summary_time2', 'ส่งสรุปเวรนอกเวลาเข้า Telegram', 'time')}
        </div>
        <div class="panel" style="margin-top:12px;background:var(--ground)">
          <label class="f">Bot token <span class="muted" style="font-size:13px">สถานะ: <b id="tg-status">กำลังตรวจ…</b></span>
            <input type="password" id="tg-token" autocomplete="off" placeholder="วาง token จาก @BotFather เช่น 7012345678:AAH…"></label>
          <div class="row" style="margin-top:8px">
            <button class="btn quiet" type="button" id="tg-save-token">บันทึก token</button>
            <button class="btn quiet" type="button" id="tg-test">ทดสอบส่งข้อความ</button>
          </div>
          <p class="muted" style="font-size:13px;margin-top:8px">ผลการส่งล่าสุด: <span id="tg-last">—</span></p>
        </div>
        <h2 style="margin-top:20px">รายการตำแหน่ง</h2>
        <label class="f">หนึ่งบรรทัดต่อหนึ่งตำแหน่ง (ใช้ในช่องเลือกตำแหน่งของหน้าเจ้าหน้าที่)
          <textarea name="positions" rows="8">${esc((s.positions || []).join('\n'))}</textarea></label>
        <button class="btn" type="submit" style="margin-top:16px">บันทึกการตั้งค่า</button>
      </form>
      <div class="panel">
        <h2>การเชื่อมต่อเครื่องสแกน HIP</h2>
        <p>รับข้อมูลล่าสุด: <b>${thaiDateTime(sync && sync.last_sync_at)}</b></p>
        <p>เวลาสแกนล่าสุดที่รับแล้ว: ${thaiDateTime(sync && sync.last_log_time)} (รายการที่ ${sync ? sync.last_scan_id : 0})</p>
        <p class="muted">ข้อมูลเข้าระบบหลังโปรแกรม HIP Time ดึงข้อมูลจากเครื่องสแกนตามเวลาที่ตั้งไว้ และตัวส่งข้อมูลทำงานทุก 5 นาที</p>
      </div>`);
    document.getElementById('st-form').onsubmit = async (ev) => {
      ev.preventDefault();
      const f = ev.target, btn = f.querySelector('button');
      const patch = {
        work_start: f.work_start.value, late_grace_min: Number(f.late_grace_min.value),
        work_end: f.work_end.value, vacancies: Number(f.vacancies.value),
        site_lat: Number(f.site_lat.value), site_lng: Number(f.site_lng.value), radius_m: Number(f.radius_m.value),
        positions: [...new Set(f.positions.value.split('\n').map((x) => x.trim()).filter(Boolean))],
        telegram_notify: f.telegram_notify.checked,
        telegram_chat_id: f.telegram_chat_id.value.trim() || null,
        telegram_topic_id: f.telegram_topic_id.value.trim() || null,
        ot_start: f.ot_start.value || '16:30', ot_end: f.ot_end.value || '18:30',
        summary_time2: f.summary_time2.value || null
      };
      busy(btn, true);
      try { await q(sb.from('settings').update(patch).eq('id', 1)); toast('บันทึกการตั้งค่าแล้ว'); }
      catch (e) { fail(e); } finally { busy(btn, false); }
    };
    const tgRefresh = async () => {
      try {
        document.getElementById('tg-status').textContent = (await q(sb.rpc('tg_token_status'))) || '—';
        document.getElementById('tg-last').textContent = (await q(sb.rpc('tg_last_result'))) || '—';
      } catch (e) { document.getElementById('tg-status').textContent = 'ยังไม่ได้รันไฟล์ 008'; }
    };
    tgRefresh();
    document.getElementById('tg-save-token').onclick = async (ev) => {
      const b = ev.target, inp = document.getElementById('tg-token');
      if (!inp.value.trim()) return toast('วาง token ก่อน');
      busy(b, true);
      try { await q(sb.rpc('set_tg_token', { p_token: inp.value })); inp.value = ''; toast('บันทึก token แล้ว'); tgRefresh(); }
      catch (e) { fail(e); } finally { busy(b, false); }
    };
    document.getElementById('tg-test').onclick = async (ev) => {
      const b = ev.target; busy(b, true);
      try {
        await q(sb.rpc('tg_test'));
        toast('ส่งแล้ว กำลังรอคำตอบจาก Telegram…');
        setTimeout(tgRefresh, 4000);
      } catch (e) { fail(e); } finally { busy(b, false); }
    };
  }

  // ---------------------------------------------------------------- ลงเวลาผ่านมือถือ
  const FACE_CDN = 'https://cdn.jsdelivr.net/npm/@vladmandic/face-api@1.7.13';
  let camStream = null, geoWatch = null;
  function stopCamera() {
    if (camStream) { camStream.getTracks().forEach((t) => t.stop()); camStream = null; }
    if (geoWatch !== null) { navigator.geolocation.clearWatch(geoWatch); geoWatch = null; }
  }
  async function loadFaceApi(status) {
    if (window.faceapi && loadFaceApi.ready) return;
    status('กำลังโหลดตัวตรวจใบหน้า (ครั้งแรกประมาณ 10 วินาที)…');
    await loadScript(FACE_CDN + '/dist/face-api.js');
    const m = FACE_CDN + '/model';
    await Promise.all([
      faceapi.nets.tinyFaceDetector.loadFromUri(m),
      faceapi.nets.faceLandmark68Net.loadFromUri(m),
      faceapi.nets.faceRecognitionNet.loadFromUri(m)
    ]);
    loadFaceApi.ready = true;
  }
  async function startCamera(video) {
    if (camStream) { camStream.getTracks().forEach((t) => t.stop()); camStream = null; }
    camStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 480 } }, audio: false });
    video.srcObject = camStream;
    await video.play();
  }
  async function readFace(video) {
    const r = await faceapi.detectSingleFace(video, new faceapi.TinyFaceDetectorOptions({ inputSize: 320, scoreThreshold: 0.5 }))
      .withFaceLandmarks().withFaceDescriptor();
    return r ? Array.from(r.descriptor) : null;
  }
  function snapJpeg(video) {
    const w = 480, h = Math.round(w * (video.videoHeight || 480) / (video.videoWidth || 640));
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const g = c.getContext('2d'); g.translate(w, 0); g.scale(-1, 1); g.drawImage(video, 0, 0, w, h);
    return new Promise((res) => c.toBlob(res, 'image/jpeg', 0.7));
  }
  function distM(lat1, lng1, lat2, lng2) {
    const R = 6371000, rad = (x) => x * Math.PI / 180;
    const a = Math.sin(rad(lat2 - lat1) / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lng2 - lng1) / 2) ** 2;
    return Math.round(2 * R * Math.asin(Math.sqrt(a)));
  }

  async function viewCheckin() {
    const [faces, settings, mine] = await Promise.all([
      q(sb.rpc('face_status')),
      q(sb.from('settings').select('site_lat, site_lng, radius_m, face_threshold').eq('id', 1).single()),
      q(sb.from('attendance_logs').select('log_time, method, in_area, reason')
        .eq('staff_id', state.me.id).gte('log_time', todayISO() + 'T00:00:00+07:00').order('log_time'))
    ]);
    const registered = faces.some((f) => f.staff_id === state.me.id);
    const tm = (ts) => new Date(ts).toLocaleTimeString('th-TH', { timeZone: 'Asia/Bangkok', hour: '2-digit', minute: '2-digit', hour12: false });
    const todayList = mine.length ? mine.map((l) => `<li>${tm(l.log_time)} · ${METHOD[l.method]}${l.in_area === false ? ' · <span class="tag away">นอกพื้นที่</span>' : ''}</li>`).join('') : '<li class="muted">ยังไม่ได้ลงเวลาวันนี้</li>';

    if (!registered) return viewFaceRegister();

    setView(`
      <div class="checkin">
        <h1>ลงเวลา</h1>
        <p class="muted">${thaiDate(todayISO(), { weekday: 'long' })}</p>
        <div class="seg" role="radiogroup" aria-label="ประเภท">
          <button type="button" role="radio" aria-checked="true" data-dir="in">ลงเวลามา</button>
          <button type="button" role="radio" aria-checked="false" data-dir="out">ลงเวลากลับ</button>
        </div>
        <div class="cam"><video id="cam" playsinline muted></video><div class="cam-ring"></div><p id="cam-msg">กำลังเปิดกล้อง…</p></div>
        <div class="panel checks">
          <div><span>ตำแหน่ง</span><b id="gps-msg">กำลังหาตำแหน่ง…</b></div>
          <label class="f" id="reason-box" hidden>เหตุผลที่ลงเวลานอกพื้นที่
            <select id="reason"><option value="">— เลือก —</option><option>ไปราชการ / ประชุม</option><option>ออกเยี่ยมบ้าน / ชุมชน</option><option>อบรม</option><option>อื่น ๆ</option></select>
          </label>
        </div>
        <button class="btn big" type="button" id="go" disabled>ยืนยันลงเวลามา</button>
        <p class="err" id="ck-err" role="alert"></p>
        <div class="panel"><h2>วันนี้</h2><ul class="plain">${todayList}</ul></div>
      </div>`);

    let dir = 'in', pos = null;
    const go = document.getElementById('go'), msg = (t) => { document.getElementById('cam-msg').textContent = t; };
    const err = document.getElementById('ck-err');
    $app.querySelectorAll('[data-dir]').forEach((b) => b.onclick = () => {
      dir = b.dataset.dir;
      $app.querySelectorAll('[data-dir]').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
      go.textContent = dir === 'in' ? 'ยืนยันลงเวลามา' : 'ยืนยันลงเวลากลับ';
    });

    // GPS
    const gpsMsg = document.getElementById('gps-msg'), reasonBox = document.getElementById('reason-box');
    if (!navigator.geolocation) gpsMsg.textContent = 'เครื่องนี้ไม่รองรับ GPS';
    else geoWatch = navigator.geolocation.watchPosition((p) => {
      pos = p.coords;
      const d = distM(settings.site_lat, settings.site_lng, pos.latitude, pos.longitude);
      const inside = d <= settings.radius_m;
      gpsMsg.innerHTML = inside ? `<span style="color:var(--green)">ในพื้นที่ · ห่าง ${d} ม.</span>`
        : `<span style="color:var(--late)">นอกพื้นที่ · ห่าง ${d >= 1000 ? (d / 1000).toFixed(1) + ' กม.' : d + ' ม.'}</span>`;
      reasonBox.hidden = inside;
      go.disabled = !loadFaceApi.ready;
    }, (e) => { gpsMsg.textContent = e.code === 1 ? 'ไม่ได้อนุญาตตำแหน่ง — เปิดสิทธิ์ Location ให้เบราว์เซอร์' : 'หาตำแหน่งไม่ได้ ลองออกไปที่โล่ง'; },
    { enableHighAccuracy: true, maximumAge: 15000, timeout: 20000 });

    // Camera + face model
    const video = document.getElementById('cam');
    try {
      await startCamera(video);
      await loadFaceApi(msg);
      msg('วางใบหน้าให้อยู่ในกรอบ');
      if (pos) go.disabled = false;
    } catch (e) {
      msg('เปิดกล้องไม่ได้');
      err.textContent = /Permission|NotAllowed/i.test(e.name + e.message) ? 'ไม่ได้อนุญาตกล้อง — เปิดสิทธิ์ Camera ให้เบราว์เซอร์แล้วรีเฟรช' : e.message;
      return;
    }

    go.onclick = async () => {
      err.textContent = '';
      if (!pos) { err.textContent = 'ยังหาตำแหน่งไม่ได้'; return; }
      const d = distM(settings.site_lat, settings.site_lng, pos.latitude, pos.longitude);
      const reason = document.getElementById('reason').value;
      if (d > settings.radius_m && !reason) { err.textContent = 'ลงเวลานอกพื้นที่ ต้องเลือกเหตุผล'; return; }
      busy(go, true); msg('กำลังตรวจใบหน้า…');
      try {
        const desc = await readFace(video);
        if (!desc) throw new Error('ไม่พบใบหน้า — หันหน้าตรง ให้มีแสงพอ แล้วลองอีกครั้ง');
        const tpl = await q(sb.from('face_templates').select('descriptor').eq('staff_id', state.me.id));
        const score = Math.min(...tpl.map((t) => faceapi.euclideanDistance(desc, t.descriptor)));
        if (!(score <= settings.face_threshold)) throw new Error('ใบหน้าไม่ตรงกับที่ลงทะเบียนไว้ (ค่า ' + score.toFixed(2) + ') ลองอีกครั้ง หรือให้ผู้ดูแลรีเซ็ตใบหน้า');
        msg('กำลังบันทึก…');
        const blob = await snapJpeg(video);
        const path = `${state.me.id}/${todayISO()}/${Date.now()}-${dir}.jpg`;
        const up = await sb.storage.from('selfies').upload(path, blob, { contentType: 'image/jpeg' });
        if (up.error) throw up.error;
        const rec = await q(sb.rpc('mobile_check_in', {
          p_direction: dir, p_lat: pos.latitude, p_lng: pos.longitude,
          p_reason: d > settings.radius_m ? reason : null, p_selfie_path: path, p_face_score: Number(score.toFixed(3))
        }));
        stopCamera();
        setView(`<div class="checkin done"><div class="ok-mark" aria-hidden="true">✓</div>
          <h1>${dir === 'in' ? 'ลงเวลามาแล้ว' : 'ลงเวลากลับแล้ว'}</h1>
          <p class="big-time">${tm(rec.log_time)}</p>
          <p>${rec.in_area ? 'ในพื้นที่ รพ.สต.' : 'นอกพื้นที่ · ' + esc(rec.reason || '')}</p>
          <a class="btn quiet" href="#/me">ดูเวลาของฉัน</a></div>`);
      } catch (e) {
        err.textContent = e.message; msg('วางใบหน้าให้อยู่ในกรอบ'); busy(go, false);
      }
    };
  }

  async function viewFaceRegister() {
    setView(`
      <div class="checkin">
        <h1>ลงทะเบียนใบหน้า</h1>
        <p class="muted">ทำครั้งเดียว ก่อนเริ่มลงเวลาผ่านมือถือ</p>
        <div class="panel" style="background:#FFF8EC;border-color:#EAD3A8">
          <b>การเก็บข้อมูลใบหน้า</b>
          <p style="margin:6px 0 8px">ระบบเก็บเฉพาะค่าตัวเลขของใบหน้า (ไม่เก็บรูป) เพื่อยืนยันตัวตนตอนลงเวลาเท่านั้น ส่วนรูปถ่ายตอนลงเวลาแต่ละครั้งผู้ดูแลระบบดูได้เพื่อตรวจสอบ ขอลบข้อมูลได้เมื่อพ้นจากหน่วยงาน</p>
          <label class="check"><input type="checkbox" id="consent"> ข้าพเจ้ายินยอมให้เก็บข้อมูลใบหน้า</label>
        </div>
        <div class="cam" hidden id="cam-wrap"><video id="cam" playsinline muted></video><div class="cam-ring"></div><p id="cam-msg"></p></div>
        <p class="steps" id="steps" hidden></p>
        <button class="btn big" type="button" id="start" disabled>เริ่มถ่ายใบหน้า</button>
        <p class="err" id="rg-err" role="alert"></p>
      </div>`);
    const consent = document.getElementById('consent'), start = document.getElementById('start'), err = document.getElementById('rg-err');
    consent.onchange = () => { start.disabled = !consent.checked; };
    const prompts = ['มองตรงที่กล้อง', 'หันหน้าไปทางซ้ายเล็กน้อย', 'หันหน้าไปทางขวาเล็กน้อย'];
    start.onclick = async () => {
      err.textContent = ''; busy(start, true);
      const video = document.getElementById('cam'), msg = (t) => { document.getElementById('cam-msg').textContent = t; };
      document.getElementById('cam-wrap').hidden = false;
      try {
        await startCamera(video);
        await loadFaceApi(msg);
        const shots = [];
        const steps = document.getElementById('steps'); steps.hidden = false;
        for (let i = 0; i < prompts.length; i++) {
          steps.textContent = `ภาพที่ ${i + 1}/3: ${prompts[i]}`;
          msg(prompts[i]);
          await new Promise((r) => setTimeout(r, 1800));
          let d = null;
          for (let tries = 0; tries < 8 && !d; tries++) { d = await readFace(video); if (!d) await new Promise((r) => setTimeout(r, 400)); }
          if (!d) throw new Error('ไม่พบใบหน้าในภาพที่ ' + (i + 1) + ' — ให้มีแสงพอ แล้วกดเริ่มใหม่');
          shots.push(d);
        }
        msg('กำลังบันทึก…');
        await q(sb.rpc('register_my_face', { p_descriptors: shots }));
        stopCamera();
        toast('ลงทะเบียนใบหน้าแล้ว');
        route();
      } catch (e) { err.textContent = e.message; busy(start, false); }
    };
  }

  // ---------------------------------------------------------------- เวลาของฉัน
  async function viewMe() {
    const params = new URLSearchParams(location.hash.split('?')[1] || '');
    const month = params.get('m') || todayISO().slice(0, 7);
    const pick = canView();
    const people = pick ? await q(sb.from('staff').select('id, full_name, hip_user_id, emp_code').eq('is_active', true).order('sort_order').order('full_name')) : [];
    const who = (pick && people.find((p) => p.id === params.get('s'))) || state.me;
    const start = month + '-01T00:00:00+07:00';
    const endD = new Date(month + '-01T12:00:00Z'); endD.setUTCMonth(endD.getUTCMonth() + 1);
    const end = endD.toISOString().slice(0, 7) + '-01T00:00:00+07:00';
    const [logs, settings] = await Promise.all([
      q(sb.from('attendance_logs').select('log_time, method, in_area, reason').eq('staff_id', who.id).gte('log_time', start).lt('log_time', end).order('log_time')),
      q(sb.from('settings').select('work_start, late_grace_min').eq('id', 1).single())
    ]);
    const lateAfter = (() => { const [h, m] = hhmm(settings.work_start).split(':').map(Number); const t = h * 60 + m + settings.late_grace_min; return t; })();
    const byDay = new Map();
    for (const l of logs) {
      const d = new Date(l.log_time).toLocaleDateString('sv-SE', { timeZone: 'Asia/Bangkok' });
      if (!byDay.has(d)) byDay.set(d, []);
      byDay.get(d).push(l);
    }
    const tm = (ts) => new Date(ts).toLocaleTimeString('th-TH', { timeZone: 'Asia/Bangkok', hour: '2-digit', minute: '2-digit', hour12: false });
    let lateCount = 0;
    const rows = [...byDay.entries()].map(([d, ls]) => {
      const first = ls[0], last = ls.length > 1 ? ls[ls.length - 1] : null;
      const [h, m] = tm(first.log_time).split(':').map(Number);
      const late = h * 60 + m > lateAfter; if (late) lateCount++;
      return `<tr><td>${thaiDate(d, { weekday: 'short' })}</td>
        <td>${tm(first.log_time)} <span class="tag none">${METHOD[first.method]}</span> ${late ? '<span class="tag late">สาย</span>' : ''}</td>
        <td>${last ? `${tm(last.log_time)} <span class="tag none">${METHOD[last.method]}</span>` : '<span class="muted">ไม่ได้สแกนกลับ</span>'}</td>
        <td>${ls.some((x) => x.in_area === false) ? '<span class="tag away">นอกพื้นที่</span>' : ''}</td>
        <td class="muted" style="font-size:14px">${ls.length > 2 ? ls.map((x) => `${tm(x.log_time)} ${METHOD[x.method]}`).join(', ') : ''}</td></tr>`;
    }).join('');
    const scanNote = who.hip_user_id ? `${who.emp_code ? 'รหัส ' + esc(who.emp_code) + ' · ' : ''}เลขในเครื่องสแกน ${esc(who.hip_user_id)}`
      : `<span class="tag late">ยังไม่ได้ใส่เลขในเครื่องสแกน</span> เวลาที่สแกนที่เครื่องจะยังไม่ขึ้น${isAdmin() ? ' — ใส่ได้ที่เมนูเจ้าหน้าที่' : ' — แจ้งผู้ดูแลระบบ'}`;
    const nowTxt = new Date().toLocaleTimeString('th-TH', { timeZone: 'Asia/Bangkok', hour: '2-digit', minute: '2-digit', hour12: false });
    setView(`
      <div class="head"><div><h1>${who.id === state.me.id ? 'เวลาของฉัน' : 'เวลาของ ' + esc(who.full_name)}</h1>
          <p class="muted">${esc(who.full_name)} · ${scanNote}</p></div>
        <div class="row">
          ${pick ? `<label class="f">เจ้าหน้าที่<select id="who">${people.map((p) => `<option value="${p.id}"${p.id === who.id ? ' selected' : ''}>${esc(p.full_name)}</option>`).join('')}</select></label>` : ''}
          <label class="f">เดือน<input type="month" id="month" value="${month}"></label>
        </div></div>
      <div class="tiles"><div class="tile ok"><b>${byDay.size}</b><span>วันที่ลงเวลา</span></div><div class="tile late"><b>${lateCount}</b><span>วันที่มาสาย</span></div></div>
      <div class="panel tbl-wrap"><table class="data"><thead><tr><th>วันที่</th><th>เวลามา</th><th>เวลากลับ</th><th></th><th>สแกนทั้งหมด</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="5" class="muted">ยังไม่มีการลงเวลาในเดือนนี้</td></tr>'}</tbody></table></div>
      <p class="muted" style="font-size:14px">รวมเวลาจากเครื่องสแกนและมือถือ · หน้านี้อัปเดตเองทุก 1 นาที (ล่าสุด ${nowTxt} น.)</p>`);
    const go = (m, sid) => { location.hash = '#/me?m=' + m + (sid && sid !== state.me.id ? '&s=' + sid : ''); };
    document.getElementById('month').onchange = (e) => { if (e.target.value) go(e.target.value, who.id); };
    const sel = document.getElementById('who');
    if (sel) sel.onchange = (e) => go(month, e.target.value);
  }

  // ---------------------------------------------------------------- start
  document.getElementById('logout').onclick = async () => { await sb.auth.signOut(); };
  window.addEventListener('hashchange', route);
  // อย่ารอ (await) คำสั่ง Supabase ภายใน onAuthStateChange โดยตรง — ทำให้ค้างได้
  // จึงเลื่อนไปทำหลัง callback จบ และกันไม่ให้โหลดซ้อนกัน
  let lastUid;
  async function refresh() {
    try { await loadSession(); } catch (e) { fail(e); }
    route();
  }
  sb.auth.onAuthStateChange((event, session) => {
    const uid = session ? session.user.id : null;
    if (event === 'INITIAL_SESSION' || event === 'SIGNED_OUT' || (event === 'SIGNED_IN' && uid !== lastUid)) {
      lastUid = uid;
      setTimeout(refresh, 0);
    }
  });
})();
