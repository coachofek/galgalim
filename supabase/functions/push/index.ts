// שולח התראות פוש (Firebase Cloud Messaging) לטלפונים של המשתמשים.
// נקרא רק מטריגרים בבסיס הנתונים (push_to), עם סוד משותף בכותרת x-push-secret.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const sa = JSON.parse(atob(Deno.env.get("FCM_SA_B64")!));

let cached: { token: string; exp: number } | null = null;

const b64url = (data: ArrayBuffer | string) =>
  btoa(typeof data === "string" ? data : String.fromCharCode(...new Uint8Array(data)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// טוקן גישה של גוגל מתוך חשבון השירות (JWT חתום RS256), נשמר עד שפג
async function googleToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 60 > now) return cached.token;
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri, iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch(sa.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${b64url(sig)}`,
    }),
  });
  const j = await res.json();
  if (!res.ok) throw new Error("google auth: " + JSON.stringify(j));
  cached = { token: j.access_token, exp: now + j.expires_in };
  return cached.token;
}

Deno.serve(async (req) => {
  const { data: ok } = await db.rpc("verify_push_secret", { s: req.headers.get("x-push-secret") ?? "" });
  if (!ok) return new Response("forbidden", { status: 403 });

  const { users, title, body, kind } = await req.json();
  const { data: rows } = await db.from("push_tokens").select("token").in("user_id", users ?? []);
  if (!rows?.length) return Response.json({ sent: 0, reason: "no tokens" });

  const access = await googleToken();
  const results = await Promise.all(rows.map(async ({ token }) => {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          data: { kind: String(kind ?? "") },
          android: {
            priority: "high",
            notification: { channel_id: "alerts", sound: "default", icon: "ic_stat_wheel", color: "#EAB308" },
          },
        },
      }),
    });
    // טלפון שהאפליקציה הוסרה ממנו — מוחקים את הטוקן
    if (res.status === 404 || res.status === 400) {
      const err = await res.json().catch(() => ({}));
      const code = err?.error?.details?.[0]?.errorCode ?? err?.error?.status;
      if (["UNREGISTERED", "INVALID_ARGUMENT"].includes(code)) await db.from("push_tokens").delete().eq("token", token);
      return { ok: false, code };
    }
    return { ok: res.ok, status: res.status };
  }));
  return Response.json({ sent: results.filter((r) => r.ok).length, results });
});
