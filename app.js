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
  const TYPE = { civil: 'ข้าราชการ', seconded: 'ยืมตัวมาช่วยราชการ', other: 'ลูกจ้าง/อื่น ๆ' };
  const LEAVE = { leave: 'ลา', official: 'ไปราชการ', other: 'อื่น ๆ' };
  const hhmm = (t) => (t ? String(t).slice(0, 5) : '');
  const todayISO = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
  const thaiDate = (iso, opts) => new Date(iso + 'T00:00:00+07:00').toLocaleDateString('th-TH', Object.assign({ timeZone: 'Asia/Bangkok', day: 'numeric', month: 'long', year: 'numeric' }, opts || {}));
  const thaiDateTime = (ts) => (ts ? new Date(ts).toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'medium', timeStyle: 'short' }) : '—');
  const isAdmin = () => state.me && state.me.role === 'admin';

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
    sheet: { title: 'ใบบัญชีลงเวลา', admin: true, render: viewSheet },
    staff: { title: 'เจ้าหน้าที่', admin: true, render: viewStaff },
    leave: { title: 'ลา / ไปราชการ', admin: true, render: viewLeave },
    settings: { title: 'ตั้งค่า', admin: true, render: viewSettings },
    me: { title: 'เวลาของฉัน', admin: false, render: viewMe }
  };

  function renderNav(current) {
    const keys = isAdmin() ? ['sheet', 'staff', 'leave', 'settings', 'me'] : ['me'];
    document.getElementById('nav').innerHTML = keys.map((k) =>
      `<a href="#/${k}"${k === current ? ' aria-current="page"' : ''}>${ROUTES[k].title}</a>`).join('');
  }

  async function route() {
    if (!state.user) return viewLogin();
    if (!state.me) return viewPending();
    let key = (location.hash.replace(/^#\/?/, '').split('?')[0]) || (isAdmin() ? 'sheet' : 'me');
    if (!ROUTES[key] || (ROUTES[key].admin && !isAdmin())) key = isAdmin() ? 'sheet' : 'me';
    document.title = ROUTES[key].title + ' · ระบบลงเวลา รพ.สต.สองคอน';
    renderNav(key);
    try { await ROUTES[key].render(); } catch (e) { fail(e); }
  }

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
    const [rows, sumRows, settings, sync] = await Promise.all([
      q(sb.rpc('daily_sheet', { p_day: day })),
      q(sb.rpc('daily_summary', { p_day: day })),
      q(sb.from('settings').select('*').eq('id', 1).single()),
      q(sb.from('device_sync').select('*').eq('id', 1).maybeSingle())
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
      <p class="muted no-print" style="font-size:14px">ข้อมูลจากเครื่องสแกนเข้าระบบล่าสุด ${thaiDateTime(sync && sync.last_sync_at)} · นับสายเมื่อมาหลัง ${hhmm(settings.work_start)} เกิน ${settings.late_grace_min} นาที</p>

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
      </article>`);

    const go = (d) => { location.hash = '#/sheet?d=' + d; };
    const shift = (n) => { const t = new Date(day + 'T12:00:00Z'); t.setUTCDate(t.getUTCDate() + n); go(t.toISOString().slice(0, 10)); };
    document.getElementById('day').onchange = (e) => e.target.value && go(e.target.value);
    document.getElementById('prev').onclick = () => shift(-1);
    document.getElementById('next').onclick = () => shift(1);
    document.getElementById('print').onclick = () => window.print();
  }

  // ---------------------------------------------------------------- เจ้าหน้าที่
  async function viewStaff() {
    const [staff, users, emails, unmatched, people] = await Promise.all([
      q(sb.from('staff').select('*').order('sort_order').order('full_name')),
      q(sb.rpc('list_unlinked_users')),
      q(sb.rpc('staff_emails')),
      q(sb.from('hip_unmatched_summary').select('*').order('enroll_number')),
      q(sb.from('hip_people').select('enroll_number'))
    ]);
    const emailOf = Object.fromEntries(emails.map((e) => [e.staff_id, e.email]));
    const known = new Set(staff.map((s) => s.hip_user_id).filter(Boolean));
    const newPeople = people.filter((p) => !known.has(p.enroll_number)).length;
    const opt = (obj, val) => Object.entries(obj).map(([k, l]) => `<option value="${k}"${k === val ? ' selected' : ''}>${l}</option>`).join('');

    const rows = staff.map((s) => `
      <tr data-id="${s.id}">
        <td><input type="number" name="sort_order" value="${s.sort_order}" style="width:56px" aria-label="ลำดับ"></td>
        <td><input name="full_name" value="${esc(s.full_name)}" style="width:100%;min-width:140px" aria-label="ชื่อ-สกุล"></td>
        <td><input name="position" value="${esc(s.position)}" style="width:100%;min-width:110px" aria-label="ตำแหน่ง"></td>
        <td><select name="staff_type" aria-label="ประเภท">${opt(TYPE, s.staff_type)}</select></td>
        <td><input name="hip_user_id" value="${esc(s.hip_user_id)}" style="width:60px" aria-label="รหัสเครื่องสแกน"></td>
        <td><select name="role" aria-label="สิทธิ์">${opt({ staff: 'เจ้าหน้าที่', admin: 'ผู้ดูแล' }, s.role)}</select></td>
        <td style="text-align:center"><input type="checkbox" name="on_sheet" ${s.on_sheet ? 'checked' : ''} aria-label="แสดงในใบบัญชี"></td>
        <td style="text-align:center"><input type="checkbox" name="is_active" ${s.is_active ? 'checked' : ''} aria-label="ใช้งาน"></td>
        <td>${emailOf[s.id] ? `<span class="tag">${esc(emailOf[s.id])}</span>` :
          (users.length ? `<select name="link" aria-label="ผูกบัญชี"><option value="">— ผูกบัญชี —</option>${users.map((u) => `<option value="${u.user_id}">${esc(u.email)}</option>`).join('')}</select>` : '<span class="tag none">ยังไม่มีบัญชี</span>')}</td>
        <td><button class="btn quiet" type="button" data-save>บันทึก</button></td>
      </tr>`).join('');

    setView(`
      <div class="head"><div><h1>เจ้าหน้าที่</h1><p class="muted">ผูกรหัสในเครื่องสแกน HIP กับชื่อ และผูกบัญชีล็อกอินของแต่ละคน</p></div>
        <div class="row">
          <button class="btn" type="button" id="import"${newPeople ? '' : ' disabled'}>นำเข้ารายชื่อจากเครื่องสแกน${newPeople ? ` (${newPeople})` : ''}</button>
          <button class="btn quiet" type="button" id="add">เพิ่มเจ้าหน้าที่</button>
        </div>
      </div>
      ${unmatched.length ? `
      <div class="panel" style="border-color:#EAD3A8;background:#FFF8EC">
        <h2>รายการสแกนที่ยังไม่รู้ว่าเป็นใคร</h2>
        <p class="muted">ใส่รหัสนี้ในช่อง "รหัสเครื่องสแกน" ของเจ้าหน้าที่ แล้วกด "ย้ายรายการค้าง"</p>
        <div class="tbl-wrap"><table class="data"><thead><tr><th>รหัสเครื่องสแกน</th><th>ชื่อในเครื่อง</th><th>จำนวน</th><th>ล่าสุด</th></tr></thead><tbody>
          ${unmatched.map((u) => `<tr><td>${esc(u.enroll_number)}</td><td>${esc(u.hip_name || '—')}</td><td>${u.scans}</td><td>${thaiDateTime(u.last_scan)}</td></tr>`).join('')}
        </tbody></table></div>
        <button class="btn quiet" type="button" id="rematch" style="margin-top:10px">ย้ายรายการค้าง</button>
      </div>` : ''}
      <div class="panel tbl-wrap">
        <table class="data compact">
          <thead><tr><th>ลำดับ</th><th>ชื่อ-สกุล</th><th>ตำแหน่ง</th><th>ประเภท</th><th>รหัสสแกน</th><th>สิทธิ์</th><th>ในใบบัญชี</th><th>ใช้งาน</th><th>บัญชีล็อกอิน</th><th></th></tr></thead>
          <tbody>${rows || '<tr><td colspan="10" class="muted">ยังไม่มีเจ้าหน้าที่ กด "นำเข้ารายชื่อจากเครื่องสแกน" หรือ "เพิ่มเจ้าหน้าที่"</td></tr>'}</tbody>
        </table>
      </div>`);

    $app.querySelectorAll('[data-save]').forEach((btn) => btn.onclick = async () => {
      const tr = btn.closest('tr'), id = tr.dataset.id, v = (n) => tr.querySelector(`[name="${n}"]`);
      const patch = {
        sort_order: Number(v('sort_order').value) || 0,
        full_name: v('full_name').value.trim(),
        position: v('position').value.trim() || null,
        staff_type: v('staff_type').value,
        hip_user_id: v('hip_user_id').value.trim() || null,
        role: v('role').value,
        on_sheet: v('on_sheet').checked,
        is_active: v('is_active').checked
      };
      if (!patch.full_name) return toast('กรอกชื่อ-สกุลก่อนบันทึก');
      if (id === state.me.id && patch.role !== 'admin' && !confirm('ถ้าเปลี่ยนสิทธิ์ของตัวเองเป็นเจ้าหน้าที่ จะเข้าหน้าผู้ดูแลไม่ได้อีก ยืนยันไหม')) return;
      busy(btn, true);
      try {
        await q(sb.from('staff').update(patch).eq('id', id));
        const link = v('link');
        if (link && link.value) await q(sb.rpc('link_staff_user', { p_staff_id: id, p_user_id: link.value }));
        toast('บันทึกแล้ว');
        await loadSession(); route();
      } catch (e) { fail(e); busy(btn, false); }
    });
    const imp = document.getElementById('import');
    imp.onclick = async () => {
      busy(imp, true);
      try { const r = await q(sb.rpc('import_hip_people')); toast(`เพิ่มเจ้าหน้าที่ ${r.new_staff} คน · ย้ายรายการสแกน ${r.moved_scans} รายการ`); route(); }
      catch (e) { fail(e); busy(imp, false); }
    };
    document.getElementById('add').onclick = async () => {
      const name = prompt('ชื่อ-สกุลของเจ้าหน้าที่');
      if (!name || !name.trim()) return;
      try {
        const max = staff.reduce((m, s) => Math.max(m, s.sort_order || 0), 0);
        await q(sb.from('staff').insert({ full_name: name.trim(), sort_order: max + 1 }));
        toast('เพิ่มแล้ว'); route();
      } catch (e) { fail(e); }
    };
    const rm = document.getElementById('rematch');
    if (rm) rm.onclick = async () => {
      busy(rm, true);
      try { const n = await q(sb.rpc('hip_rematch')); toast(`ย้ายรายการค้าง ${n} รายการ`); route(); }
      catch (e) { fail(e); busy(rm, false); }
    };
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
    setView(`
      <div class="head"><div><h1>ลา / ไปราชการ</h1><p class="muted">บันทึกวันที่เจ้าหน้าที่ลาหรือไปราชการ เพื่อให้ใบบัญชีนับถูกช่อง</p></div></div>
      <form class="panel" id="lv-form">
        <h2>บันทึกใหม่</h2>
        <div class="grid2">
          <label class="f">เจ้าหน้าที่<select name="staff_id" required>${staff.map((s) => `<option value="${s.id}">${esc(s.full_name)}</option>`).join('')}</select></label>
          <label class="f">ตั้งแต่วันที่<input type="date" name="from" value="${todayISO()}" required></label>
          <label class="f">ถึงวันที่<input type="date" name="to" value="${todayISO()}" required></label>
          <label class="f">ประเภท<select name="kind">${Object.entries(LEAVE).map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
          <label class="f" style="grid-column:1/-1">รายละเอียด (ไม่บังคับ)<input name="note" placeholder="เช่น ลาป่วย, ประชุมที่ สสอ.โพธิ์ไทร"></label>
        </div>
        <button class="btn" type="submit" style="margin-top:12px">บันทึก</button>
      </form>
      <div class="panel">
        <div class="head" style="margin-bottom:8px"><h2 style="margin:0">รายการเดือนนี้</h2>
          <label class="f">เดือน<input type="month" id="month" value="${month}"></label></div>
        <div class="tbl-wrap"><table class="data"><thead><tr><th>วันที่</th><th>เจ้าหน้าที่</th><th>ประเภท</th><th>รายละเอียด</th><th></th></tr></thead><tbody>
          ${leaves.map((l) => `<tr><td>${thaiDate(l.day, { weekday: 'short' })}</td><td>${esc(nameOf[l.staff_id] || '—')}</td>
            <td><span class="tag ${l.kind === 'official' ? 'away' : 'none'}">${LEAVE[l.kind]}</span></td><td>${esc(l.note)}</td>
            <td><button class="btn danger" type="button" data-del="${l.id}">ลบ</button></td></tr>`).join('') ||
            '<tr><td colspan="5" class="muted">ยังไม่มีรายการในเดือนนี้</td></tr>'}
        </tbody></table></div>
      </div>`);

    document.getElementById('month').onchange = (e) => { if (e.target.value) location.hash = '#/leave?m=' + e.target.value; };
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
        site_lat: Number(f.site_lat.value), site_lng: Number(f.site_lng.value), radius_m: Number(f.radius_m.value)
      };
      busy(btn, true);
      try { await q(sb.from('settings').update(patch).eq('id', 1)); toast('บันทึกการตั้งค่าแล้ว'); }
      catch (e) { fail(e); } finally { busy(btn, false); }
    };
  }

  // ---------------------------------------------------------------- เวลาของฉัน
  async function viewMe() {
    const params = new URLSearchParams(location.hash.split('?')[1] || '');
    const month = params.get('m') || todayISO().slice(0, 7);
    const start = month + '-01T00:00:00+07:00';
    const endD = new Date(month + '-01T12:00:00Z'); endD.setUTCMonth(endD.getUTCMonth() + 1);
    const end = endD.toISOString().slice(0, 7) + '-01T00:00:00+07:00';
    const [logs, settings] = await Promise.all([
      q(sb.from('attendance_logs').select('log_time, method, in_area, reason').eq('staff_id', state.me.id).gte('log_time', start).lt('log_time', end).order('log_time')),
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
        <td>${ls.some((x) => x.in_area === false) ? '<span class="tag away">นอกพื้นที่</span>' : ''}</td></tr>`;
    }).join('');
    setView(`
      <div class="head"><div><h1>เวลาของฉัน</h1><p class="muted">${esc(state.me.full_name)}</p></div>
        <label class="f">เดือน<input type="month" id="month" value="${month}"></label></div>
      <div class="tiles"><div class="tile ok"><b>${byDay.size}</b><span>วันที่ลงเวลา</span></div><div class="tile late"><b>${lateCount}</b><span>วันที่มาสาย</span></div></div>
      <div class="panel tbl-wrap"><table class="data"><thead><tr><th>วันที่</th><th>เวลามา</th><th>เวลากลับ</th><th></th></tr></thead>
        <tbody>${rows || '<tr><td colspan="4" class="muted">ยังไม่มีการลงเวลาในเดือนนี้</td></tr>'}</tbody></table></div>`);
    document.getElementById('month').onchange = (e) => { if (e.target.value) location.hash = '#/me?m=' + e.target.value; };
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
