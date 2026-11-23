/* =====================================================================
   حصن | database.js
   طبقة الاتصال بـ Supabase: التسجيل، التقدم، النقاط، لوحة النتائج، وأدوات المشرف.
   الاستخدام: أضف supabase-js ثم هذا الملف قبل سكربت الصفحة، وستجد الكائن window.HisnDB
   ===================================================================== */
(function (w) {
  "use strict";

  /* ★ عدّل هاتين القيمتين من: Supabase > Project Settings > API
     (مفتاح anon / public فقط — لا تضع service_role هنا أبداً) */
  var SUPABASE_URL = "https://ufggvniujyvpxjhulgxm.supabase.co";
  var SUPABASE_ANON_KEY = "sb_publishable_28ykfTeXSRY7kyMdMXjTyQ_sUb8xgwT";

  var PLAYER_KEY = "hisn:player:v1";
  var client = null;

  var MSG = {
    TEAM_FULL: "اكتمل عدد أعضاء هذا الفريق (6 مشاركين). اختر فريقاً آخر.",
    NAME_TAKEN: "هذا الاسم مستخدم مسبقاً، اختر اسماً آخر.",
    INVALID_NAME: "الاسم يجب أن يكون بين 2 و30 حرفاً.",
    INVALID_TEAM: "الفريق غير صالح.",
    INVALID_SESSION: "جلسة المتسابق غير صالحة، سجّل من جديد.",
    INVALID_DATA: "البيانات غير صالحة.",
    NOT_ADMIN: "ليس لديك صلاحية المشرف.",
    NOT_CONFIGURED: "لم يتم ربط قاعدة البيانات بعد."
  };

  function fail(raw) {
    var s = String(raw && raw.message ? raw.message : raw || "");
    var code = Object.keys(MSG).filter(function (k) { return s.indexOf(k) > -1; })[0];
    var e = new Error(code ? MSG[code] :
      (/fetch|network/i.test(s) ? "تعذّر الاتصال بالخادم، تحقق من الإنترنت." : (s || "خطأ غير معروف")));
    e.code = code || "UNKNOWN";
    return e;
  }

  function configured() {
    return /^https:\/\/[a-z0-9-]+\.supabase\.co/i.test(SUPABASE_URL) &&
           SUPABASE_URL.indexOf("YOUR-") < 0 && SUPABASE_ANON_KEY.indexOf("YOUR-") < 0;
  }

  function init() {
    if (client) return client;
    if (!configured() || !w.supabase) return null;
    client = w.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { persistSession: true, autoRefreshToken: true }
    });
    return client;
  }

  async function rpc(name, args) {
    var c = init();
    if (!c) throw fail("NOT_CONFIGURED");
    var r;
    try { r = await c.rpc(name, args || {}); } catch (e) { throw fail(e); }
    if (r.error) throw fail(r.error.message);
    return r.data;
  }

  /* ---------- هوية المتسابق (محفوظة في المتصفح) ---------- */
  function getPlayer() {
    try { return JSON.parse(localStorage.getItem(PLAYER_KEY) || "null"); } catch (e) { return null; }
  }
  function setPlayer(p) {
    try { p ? localStorage.setItem(PLAYER_KEY, JSON.stringify(p)) : localStorage.removeItem(PLAYER_KEY); } catch (e) {}
  }

  async function register(name, teamId) {
    var d = await rpc("register_participant", { p_name: name, p_team: teamId });
    setPlayer({ id: d.id, token: d.token, name: d.name, team_id: d.team_id });
    return getPlayer();
  }

  async function saveProgress(track) {
    var p = getPlayer();
    if (!p || !configured()) return;
    try {
      await rpc("save_progress", { p_participant: p.id, p_token: p.token, p_track: track });
    } catch (e) {
      if (e.code === "INVALID_SESSION") setPlayer(null);   // تم مسح البيانات من المشرف
      throw e;
    }
  }

  async function syncProgress(tracks) {
    for (var i = 0; i < tracks.length; i++) {
      try { await saveProgress(tracks[i]); } catch (e) { if (e.code === "INVALID_SESSION") break; }
    }
  }

  /* تُستدعى من صفحة المسابقة عند حل تحدٍّ: HisnDB.addScore("team", 20, "challenge-3") */
  async function addScore(track, points, ref) {
    var p = getPlayer();
    if (!p) throw fail("INVALID_SESSION");
    return rpc("add_score", { p_participant: p.id, p_token: p.token, p_track: track, p_points: points, p_ref: ref || "" });
  }

  function leaderboard() { return rpc("leaderboard"); }
  /* ملخص كل جهة: النقاط + عدد التحديات المحلولة + عدد المشتركين */
  function sideStats() { return rpc("side_stats"); }

  /* ---------- المشرف ---------- */
  async function signIn(email, password) {
    var c = init();
    if (!c) throw fail("NOT_CONFIGURED");
    var r = await c.auth.signInWithPassword({ email: email, password: password });
    if (r.error) throw new Error("بيانات الدخول غير صحيحة.");
    return r.data;
  }
  async function signOut() { var c = init(); if (c) await c.auth.signOut(); }
  async function hasSession() {
    var c = init(); if (!c) return false;
    var r = await c.auth.getSession();
    return !!(r.data && r.data.session);
  }
  async function isAdmin() {
    if (!(await hasSession())) return false;
    try { return !!(await rpc("is_admin")); } catch (e) { return false; }
  }

  function adminExport() { return rpc("admin_export"); }
  function adminImport(data, mode) { return rpc("admin_import", { p_data: data, p_mode: mode === "merge" ? "merge" : "replace" }); }
  function adminClear(scope) { return rpc("admin_clear", { p_scope: scope }); }
  function adminIntegrity() { return rpc("admin_integrity"); }
  function adminAddScore(id, pts, note) { return rpc("admin_add_score", { p_participant: id, p_points: pts, p_note: note || "" }); }
  function adminRemove(id) { return rpc("admin_remove_participant", { p_id: id }); }

  /* تحديث لحظي: يستدعي cb عند أي تغيير في المشاركين/النقاط/التقدم (للمشرف) */
  function subscribe(cb) {
    var c = init();
    if (!c) return function () {};
    var ch = c.channel("hisn-live");
    ["participants", "scores", "progress"].forEach(function (t) {
      ch.on("postgres_changes", { event: "*", schema: "public", table: t }, cb);
    });
    ch.subscribe();
    return function () { c.removeChannel(ch); };
  }

  w.HisnDB = {
    configured: configured, getPlayer: getPlayer, setPlayer: setPlayer,
    register: register, saveProgress: saveProgress, syncProgress: syncProgress, addScore: addScore,
    leaderboard: leaderboard, sideStats: sideStats,
    signIn: signIn, signOut: signOut, isAdmin: isAdmin,
    adminExport: adminExport, adminImport: adminImport, adminClear: adminClear,
    adminIntegrity: adminIntegrity, adminAddScore: adminAddScore, adminRemove: adminRemove,
    subscribe: subscribe
  };
})(window);
