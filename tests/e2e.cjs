// בדיקה אוטומטית של אפליקציית האנדרואיד על טלפון וירטואלי (אמולטור) בענן של גיטהאב.
// מתקינה את האפליקציה האמיתית, מתחברת כנהג-בדיקה, ובודקת: מיקום ברקע, רישום להתראות,
// התראה שמגיעה כשהאפליקציה ברקע, ואישור נסיעה עד הסוף. צילומי מסך לכל שלב.
const { execSync } = require("child_process");
const fs = require("fs");

const APP = "il.galgalim.app";
const URL = "https://tzddvgvfewomnjkleobb.supabase.co";
const KEY = "sb_publishable_4LMyQvo5dGS_6xGL_uMoXA_Xyj4Sm_v";
const OWNER = { email: "test-owner@galgalim.test", password: process.env.TEST_OWNER_PASSWORD };
const DRIVER = { email: "test-driver@galgalim.test", password: process.env.TEST_DRIVER_PASSWORD };
const OUT = "e2e-out";
fs.mkdirSync(OUT, { recursive: true });

const sh = (c) => execSync(c, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
let shotN = 0;
const shot = (name) => {
  const f = `${OUT}/${String(++shotN).padStart(2, "0")}-${name}.png`;
  execSync(`adb exec-out screencap -p > ${f}`, { shell: "/bin/bash" });
};
async function step(name, fn) {
  try { const info = await fn(); results.push(["✅", name, info ?? ""]); console.log("PASS", name, info ?? ""); }
  catch (e) { results.push(["❌", name, String(e.message || e)]); console.log("FAIL", name, e.message || e); try { shot("FAIL"); } catch {} }
}
async function poll(fn, ms = 60000, every = 2000) {
  const end = Date.now() + ms; let last;
  while (Date.now() < end) { try { last = await fn(); if (last) return last; } catch (e) { last = e.message; } await sleep(every); }
  throw new Error("timeout" + (last ? ": " + JSON.stringify(last) : ""));
}

// ---- חיבור ל-WebView דרך DevTools ----
let ws, msgId = 0, connPid = null; const pending = new Map(); const restarts = [];
async function connectWebView() {
  const pid = await poll(() => sh(`adb shell pidof ${APP}`) || null, 30000);
  if (connPid && pid !== connPid) restarts.push(new Date().toISOString().slice(11, 19));
  connPid = pid; try { ws?.close(); } catch {}
  await poll(() => sh("adb shell cat /proc/net/unix").includes(`webview_devtools_remote_${pid}`), 30000);
  sh(`adb forward tcp:9222 localabstract:webview_devtools_remote_${pid}`);
  const page = await poll(async () => {
    const list = await (await fetch("http://127.0.0.1:9222/json")).json();
    return list.find((p) => p.type === "page" && p.url.startsWith("https://localhost"));
  }, 30000);
  ws = new WebSocket(page.webSocketDebuggerUrl);
  ws.onmessage = (m) => { const d = JSON.parse(m.data); if (pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } };
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
}
async function evalJs(expr) {
  let pid = ""; try { pid = sh(`adb shell pidof ${APP}`); } catch {}
  if (!pid) { sh(`adb shell am start -n ${APP}/.MainActivity`); await sleep(6000); }
  if (!pid || pid !== connPid) await connectWebView();
  return evalRaw(expr);
}
function evalRaw(expr) {
  return new Promise((resolve, reject) => {
    const id = ++msgId;
    pending.set(id, (d) => {
      if (d.result?.exceptionDetails) reject(new Error(d.result.exceptionDetails.exception?.description || "js error"));
      else resolve(d.result?.result?.value);
    });
    ws.send(JSON.stringify({ id, method: "Runtime.evaluate", params: { expression: expr, awaitPromise: true, returnByValue: true } }));
    setTimeout(() => pending.has(id) && (pending.delete(id), reject(new Error("eval timeout"))), 30000);
  });
}

// ---- המנהל (בעלים-בדיקה) פועל ישירות מול השרת, כמו מטלפון אחר ----
async function ownerApi() {
  const t = await (await fetch(`${URL}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { apikey: KEY, "Content-Type": "application/json" }, body: JSON.stringify(OWNER),
  })).json();
  const h = { apikey: KEY, Authorization: "Bearer " + t.access_token, "Content-Type": "application/json" };
  return {
    rpc: async (fn, args) => { const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, { method: "POST", headers: h, body: JSON.stringify(args) }); const j = await r.json().catch(() => null); if (!r.ok) throw new Error(JSON.stringify(j)); return j; },
    get: async (path) => (await fetch(`${URL}/rest/v1/${path}`, { headers: h })).json(),
  };
}

(async () => {
  const owner = await ownerApi();
  const [fleet] = await owner.get("fleets?select=id");
  const [drv] = await owner.get(`drivers?select=id,status&fleet_id=eq.${fleet.id}`);
  // ניקוי שאריות מריצה קודמת: נסיעה פעילה שנתקעה
  for (const t of await owner.get(`trips?select=id&status=eq.active&driver_id=eq.${drv.id}`)) {
    await owner.rpc("finish_trip", { p_trip: t.id, p_collected: 0, p_pay: "מזומן", p_note: "ניקוי בדיקה" }).catch(() => {});
  }

  sh("adb install -r app-debug.apk");
  for (const p of ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "POST_NOTIFICATIONS"]) {
    try { sh(`adb shell pm grant ${APP} android.permission.${p}`); } catch {}
  }
  sh("adb emu geo fix 35.2137 31.7683"); // ירושלים
  sh(`adb shell am start -n ${APP}/.MainActivity`);
  await sleep(8000);

  await step("האפליקציה נפתחת ורצה כאפליקציה נייטיבית", async () => {
    await connectWebView();
    const native = await poll(() => evalJs("typeof NATIVE!=='undefined' && NATIVE"), 20000);
    const screen = await poll(() => evalJs("document.querySelector('.scr.on')?.id"), 20000);
    shot("launch");
    if (!native) throw new Error("NATIVE=false");
    return "מסך: " + screen;
  });

  await step("התחברות כנהג", async () => {
    await evalJs(`(async()=>{const r=await db.auth.signInWithPassword(${JSON.stringify(DRIVER)});if(r.error)throw new Error(r.error.message);await boot();})()`);
    const role = await poll(() => evalJs("me&&me.role"), 20000);
    await sleep(2000); shot("driver-home");
    if (role !== "driver") throw new Error("role=" + role);
    return "נכנס כ" + (await evalJs("me.driver.name"));
  });

  await step("הטלפון נרשם להתראות פוש (Firebase)", async () => {
    const n = await poll(() => evalJs("(async()=>{const{data}=await db.from('push_tokens').select('token');return data?.length||0})()"), 90000, 3000);
    return n + " טוקן רשום";
  });

  await step("מיקום GPS נשלח לשרת", async () => {
    await sleep(3000);
    sh("adb emu geo fix 35.2200 31.7800");
    const p = await poll(async () => { const [d] = await owner.get(`drivers?select=lat,lng&id=eq.${drv.id}`); return d.lat && Math.abs(d.lat - 31.78) < 0.001 ? d : null; }, 60000, 3000);
    return `${p.lat.toFixed(4)}, ${p.lng.toFixed(4)}`;
  });

  await step("מיקום ממשיך להישלח כשהאפליקציה ברקע", async () => {
    sh("adb shell input keyevent KEYCODE_HOME");
    await sleep(5000);
    sh("adb emu geo fix 35.2300 31.7900");
    const p = await poll(async () => { const [d] = await owner.get(`drivers?select=lat&id=eq.${drv.id}`); return Math.abs(d.lat - 31.79) < 0.001 ? d : null; }, 60000, 3000);
    shot("background-home");
    return "עודכן ל-" + p.lat.toFixed(4);
  });

  let offer;
  await step("התראה מגיעה כשהאפליקציה ברקע", async () => {
    offer = await owner.rpc("send_offer", {
      p_fleet: fleet.id, p_target: drv.id, p_from: "תחנה מרכזית", p_from_lat: 31.789, p_from_lng: 35.203,
      p_to: "מלחה", p_to_lat: 31.751, p_to_lng: 35.187, p_amount: 55, p_pay: "מזומן", p_note: "בדיקה אוטומטית",
      p_source: "direct", p_journal: null,
    });
    const found = await poll(() => {
      const d = sh("adb shell dumpsys notification --noredact");
      return d.includes("נסיעה חדשה") ? true : null;
    }, 60000, 3000);
    sh("adb shell cmd statusbar expand-notifications"); await sleep(2500); shot("notification");
    sh("adb shell cmd statusbar collapse");
    return found && "ההתראה הופיעה בטלפון";
  });

  await step("הנהג רואה את ההצעה ומאשר", async () => {
    sh(`adb shell am start -n ${APP}/.MainActivity`); await sleep(4000);
    await poll(() => evalJs("myOffers().length"), 30000);
    shot("offer-card");
    await evalJs(`(async()=>{await rpc('accept_offer',{p_offer:${JSON.stringify(offer.id)}});await loadAll();render()})()`);
    await sleep(2000); shot("trip-active");
    const t = await poll(() => evalJs("myTrip()&&myTrip().status"), 20000);
    return "סטטוס נסיעה: " + t;
  });

  await step("המנהל מקבל עדכון שהנסיעה נלקחה", async () => {
    const [st] = await owner.get(`drivers?select=status&id=eq.${drv.id}`);
    if (st.status !== "busy") throw new Error("סטטוס נהג " + st.status);
    return "הנהג מסומן 'בנסיעה'";
  });

  await step("איסוף וסיום עם דיווח גבייה", async () => {
    const tid = await evalJs("myTrip().id");
    await evalJs(`(async()=>{await rpc('pickup_trip',{p_trip:'${tid}'});await rpc('finish_trip',{p_trip:'${tid}',p_collected:60,p_pay:'מזומן',p_note:'בדיקה'});await loadAll();render()})()`);
    await sleep(2000); shot("trip-done");
    const [t] = await owner.get(`trips?select=status,agreed_amount,collected_amount&id=eq.${tid}`);
    if (t.status !== "done") throw new Error(JSON.stringify(t));
    return `סוכם ₪${t.agreed_amount}, נגבה ₪${t.collected_amount}`;
  });

  // שגיאות JavaScript מהאפליקציה
  try { fs.writeFileSync(`${OUT}/logcat.txt`, sh("adb logcat -d -s Capacitor/Console:* Capacitor:* chromium:* AndroidRuntime:* ActivityManager:I")); } catch {}
  try { fs.writeFileSync(`${OUT}/crash.txt`, sh("adb logcat -d -b crash")); } catch {}
  if (restarts.length) results.push(["⚠", "האפליקציה הופעלה מחדש באמצע", restarts.join(", ")]);

  const ok = results.every((r) => r[0] !== "❌");
  const md = `# בדיקת אנדרואיד אוטומטית — ${ok ? "✅ הכל עבר" : "❌ יש כשלים"}\n\n| | שלב | פרטים |\n|---|---|---|\n` +
    results.map((r) => `| ${r[0]} | ${r[1]} | ${String(r[2]).replace(/\|/g, "/")} |`).join("\n") + "\n";
  fs.writeFileSync(`${OUT}/report.md`, md);
  console.log(md);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, md);
  ws?.close();
  process.exit(ok ? 0 : 1);
})().catch((e) => { console.error(e); process.exit(1); });
