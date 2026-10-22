import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "image/webp", "application/pdf"]);
const MAX_BYTES = 5 * 1024 * 1024;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply({ error: "Server configuration unavailable" }, 500);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return reply({ error: "Authorization required" }, 401);

  let input: Record<string, unknown>;
  try {
    input = await req.json();
  } catch {
    return reply({ error: "Invalid JSON body" }, 400);
  }

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const adminClient = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const action = input.action;
  if (action === "create-proof-upload") {
    // Student portal bearer tokens are custom session tokens, not Supabase Auth JWTs.
    // They must be passed in student_session_token and validated by the dedicated RPC.
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    const accountId = typeof input.fee_account_id === "string" ? input.fee_account_id : "";
    const fileName = typeof input.file_name === "string" ? input.file_name : "";
    const contentType = typeof input.content_type === "string" ? input.content_type : "";
    const size = Number(input.size_bytes);
    if (token.length < 32 || token.length > 256 || !UUID_RE.test(accountId)) {
      return reply({ error: "Invalid student session or fee account" }, 400);
    }
    if (!ALLOWED_TYPES.has(contentType) || !Number.isInteger(size) || size <= 0 || size > MAX_BYTES) {
      return reply({ error: "Unsupported file type or file exceeds 5 MB" }, 400);
    }
    const safeName = fileName.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-80) || "proof";
    const { data: summary, error: summaryError } = await adminClient.rpc("fee_student_summary_by_session", { p_token: token });
    if (summaryError || !Array.isArray(summary) || !summary.some((row: { fee_account_id?: string }) => row.fee_account_id === accountId)) {
      return reply({ error: "Fee account not available for this student session" }, 403);
    }
    // Object path is generated server-side and is not exposed as a public URL.
    const objectPath = `${accountId}/${crypto.randomUUID()}-${safeName}`;
    const { data, error } = await adminClient.storage.from("fee-payment-proofs").createSignedUploadUrl(objectPath, { upsert: false });
    if (error || !data?.signedUrl || !data?.token) {
      return reply({ error: "Unable to prepare private upload" }, 500);
    }
    return reply({ object_path: objectPath, signed_url: data.signedUrl, upload_token: data.token, content_type: contentType, expires_in_seconds: 120 });
  }

  if (action === "admin-review-payment") {
    const submissionId = typeof input.submission_id === "string" ? input.submission_id : "";
    if (!UUID_RE.test(submissionId) || typeof input.approve !== "boolean") return reply({ error: "Invalid review request" }, 400);
    const { data: result, error } = await userClient.rpc("fee_admin_review_payment", {
      p_submission_id: submissionId,
      p_approve: input.approve,
      p_reason: typeof input.reason === "string" ? input.reason : null,
    });
    if (error) return reply({ error: error.message }, 403);
    return reply({ status: result });
  }

  if (action === "principal-confirm-payment") {
    const submissionId = typeof input.submission_id === "string" ? input.submission_id : "";
    if (!UUID_RE.test(submissionId) || typeof input.confirm !== "boolean") return reply({ error: "Invalid confirmation request" }, 400);
    const { data: result, error } = await userClient.rpc("fee_principal_confirm_payment", {
      p_submission_id: submissionId,
      p_confirm: input.confirm,
      p_reason: typeof input.reason === "string" ? input.reason : null,
    });
    if (error) return reply({ error: error.message }, 403);
    return reply({ result });
  }

  return reply({ error: "Unsupported action" }, 400);
});
