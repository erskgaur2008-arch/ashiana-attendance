import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers });
const categories = new Set(["school_notice", "leave_status", "homework_timetable", "attendance_update"]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 503);

  const auth = req.headers.get("Authorization") || "";
  const client = createClient(url, anon, { global: { headers: { Authorization: auth } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData, error: userError } = await client.auth.getUser();
  if (userError || !userData.user) return json({ error: "AUTH_REQUIRED" }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "INVALID_JSON" }, 400); }
  const action = String(body.action || "");
  const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY") || "";
  const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY") || "";
  const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "";

  if (action === "config") return json({ vapidPublicKey: vapidPublic, webPushConfigured: Boolean(vapidPublic && vapidPrivate && vapidSubject) });

  if (action === "subscribe") {
    if (!vapidPublic || !vapidPrivate || !vapidSubject) return json({ error: "WEB_PUSH_NOT_CONFIGURED" }, 503);
    const subscription = body.subscription as Record<string, unknown> | undefined;
    const endpoint = String(subscription?.endpoint || "");
    if (!endpoint.startsWith("https://") || !subscription?.keys || typeof subscription.keys !== "object") return json({ error: "INVALID_SUBSCRIPTION" }, 400);
    const { error } = await client.from("push_subscriptions").upsert({
      user_id: userData.user.id, platform: "web", endpoint, subscription,
      device_token: null, updated_at: new Date().toISOString(),
    }, { onConflict: "user_id,endpoint" });
    if (error) return json({ error: "SUBSCRIPTION_SAVE_FAILED" }, 400);
    return json({ success: true });
  }

  if (action === "unsubscribe") {
    const endpoint = String(body.endpoint || "");
    if (!endpoint.startsWith("https://")) return json({ error: "INVALID_ENDPOINT" }, 400);
    const { error } = await client.from("push_subscriptions").delete().eq("user_id", userData.user.id).eq("platform", "web").eq("endpoint", endpoint);
    if (error) return json({ error: "UNSUBSCRIBE_FAILED" }, 400);
    return json({ success: true });
  }

  if (action === "send") {
    const service = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: admins, error: adminError } = await service.from("admin_users").select("email").eq("active", true).ilike("email", userData.user.email || "");
    if (adminError || !admins?.length) return json({ error: "ADMIN_ONLY" }, 403);
    const category = String(body.category || "");
    const title = String(body.title || "").trim().slice(0, 120);
    const message = String(body.message || "").trim().slice(0, 500);
    const userIds = Array.isArray(body.userIds) ? body.userIds.map(String).filter((id) => /^[0-9a-f-]{36}$/i.test(id)).slice(0, 500) : [];
    if (!categories.has(category) || !title || !message || !userIds.length) return json({ error: "INVALID_NOTIFICATION" }, 400);
    if (!vapidPublic || !vapidPrivate || !vapidSubject) return json({ error: "WEB_PUSH_NOT_CONFIGURED" }, 503);
    webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
    const { data: rows, error } = await service.from("push_subscriptions").select("id,subscription").eq("platform", "web").in("user_id", userIds);
    if (error) return json({ error: "SUBSCRIPTION_LOOKUP_FAILED" }, 500);
    let sent = 0, failed = 0;
    for (const row of rows || []) {
      try {
        await webpush.sendNotification(row.subscription, JSON.stringify({ title, body: message, category, tag: category + ":" + crypto.randomUUID() }));
        sent++;
      } catch (e) {
        failed++;
        const status = Number((e as { statusCode?: number })?.statusCode || 0);
        if (status === 404 || status === 410) await service.from("push_subscriptions").delete().eq("id", row.id);
      }
    }
    return json({ success: true, sent, failed });
  }

  return json({ error: "UNKNOWN_ACTION" }, 400);
});
