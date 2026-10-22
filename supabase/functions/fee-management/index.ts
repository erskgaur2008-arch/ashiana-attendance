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

  if (action === "student-summary") {
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    if (token.length < 32 || token.length > 256) return reply({ error: "Invalid student session" }, 400);
    const { data, error } = await adminClient.rpc("fee_student_summary_by_session", { p_token: token });
    if (error) return reply({ error: "Unable to load fee summary" }, 403);
    return reply({ accounts: data ?? [] });
  }

  if (action === "submit-payment") {
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    const accountId = typeof input.fee_account_id === "string" ? input.fee_account_id : "";
    const objectPath = typeof input.proof_object_path === "string" ? input.proof_object_path : "";
    const reference = typeof input.upi_reference === "string" ? input.upi_reference.trim() : "";
    const amount = Number(input.amount_paise);
    if (token.length < 32 || token.length > 256 || !UUID_RE.test(accountId) ||
        !Number.isSafeInteger(amount) || amount <= 0 || amount > 1000000000 ||
        reference.length < 6 || reference.length > 120 ||
        !objectPath.startsWith(accountId + "/") || objectPath.includes("..") || objectPath.startsWith("/")) {
      return reply({ error: "Invalid payment submission details" }, 400);
    }
    const { data: summary, error: summaryError } = await adminClient.rpc("fee_student_summary_by_session", { p_token: token });
    if (summaryError || !Array.isArray(summary) || !summary.some((row: { fee_account_id?: string }) => row.fee_account_id === accountId)) {
      return reply({ error: "Fee account not available for this student session" }, 403);
    }
    const { data: objects, error: objectError } = await adminClient.storage.from("fee-payment-proofs").list(accountId, {
      search: objectPath.slice(accountId.length + 1),
      limit: 10,
    });
    const objectName = objectPath.slice(accountId.length + 1);
    if (objectError || !objects?.some((obj: { name: string }) => obj.name === objectName)) {
      return reply({ error: "Upload the required payment screenshot before submitting" }, 400);
    }
    const { data, error } = await adminClient.rpc("fee_submit_payment_by_session", {
      p_token: token,
      p_fee_account_id: accountId,
      p_amount_paise: amount,
      p_upi_reference: reference,
      p_proof_object_path: objectPath,
      p_student_note: typeof input.student_note === "string" ? input.student_note.slice(0, 1000) : null,
    });
    if (error) return reply({ error: error.message }, 400);
    return reply({ submission_id: data, status: "PENDING_ADMIN" }, 201);
  }

  if (action === "student-receipts") {
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    if (token.length < 32 || token.length > 256) return reply({ error: "Invalid student session" }, 400);
    const { data, error } = await adminClient.rpc("fee_student_receipts_by_session", { p_token: token });
    if (error) return reply({ error: "Unable to load receipts" }, 403);
    return reply({ receipts: data ?? [] });
  }

  if (action === "admin-queue" || action === "principal-queue") {
    // Authorization is enforced inside the corresponding SECURITY DEFINER RPC.
    const rpcName = action === "admin-queue" ? "fee_admin_payment_queue" : "fee_principal_payment_queue";
    const { data, error } = await userClient.rpc(rpcName);
    if (error) return reply({ error: error.message }, 403);
    return reply({ submissions: data ?? [] });
  }

  if (action === "admin-save-academic-year") {
    const label = typeof input.label === "string" ? input.label.trim() : "";
    const startsOn = typeof input.starts_on === "string" ? input.starts_on : "";
    const endsOn = typeof input.ends_on === "string" ? input.ends_on : "";
    if (label.length < 4 || label.length > 40 || !/^\\d{4}-\\d{2}-\\d{2}$/.test(startsOn) || !/^\\d{4}-\\d{2}-\\d{2}$/.test(endsOn) || startsOn > endsOn || typeof input.is_active !== "boolean") {
      return reply({ error: "Provide a valid academic-year label and date range" }, 400);
    }
    const { data, error } = await userClient.rpc("fee_admin_save_academic_year", { p_label: label, p_starts_on: startsOn, p_ends_on: endsOn, p_is_active: input.is_active });
    if (error) return reply({ error: error.message }, 403);
    return reply({ academic_year_id: data });
  }

  if (action === "admin-save-structure") {
    const yearId = typeof input.academic_year_id === "string" ? input.academic_year_id : "";
    const className = typeof input.class_name === "string" ? input.class_name.trim() : "";
    const feeName = typeof input.fee_name === "string" ? input.fee_name.trim() : "";
    const amountPaise = Number(input.amount_paise);
    const dueDate = typeof input.due_date === "string" && /^\\d{4}-\\d{2}-\\d{2}$/.test(input.due_date) ? input.due_date : null;
    if (!UUID_RE.test(yearId) || !className || feeName.length < 2 || feeName.length > 100 || !Number.isSafeInteger(amountPaise) || amountPaise < 0 || typeof input.is_mandatory !== "boolean") {
      return reply({ error: "Provide a valid academic year, class, fee name and amount" }, 400);
    }
    const { data, error } = await userClient.rpc("fee_admin_save_structure", { p_academic_year_id: yearId, p_class_name: className, p_fee_name: feeName, p_amount_paise: amountPaise, p_is_mandatory: input.is_mandatory, p_due_date: dueDate });
    if (error) return reply({ error: error.message }, 403);
    return reply({ fee_structure_id: data });
  }

  if (action === "admin-assign-student-account") {
    const yearId = typeof input.academic_year_id === "string" ? input.academic_year_id : "";
    const studentId = typeof input.student_id === "string" ? input.student_id : "";
    if (!UUID_RE.test(yearId) || !UUID_RE.test(studentId)) return reply({ error: "Valid academic year and student IDs are required" }, 400);
    const { data, error } = await userClient.rpc("fee_admin_assign_student_account", { p_academic_year_id: yearId, p_student_id: studentId });
    if (error) return reply({ error: error.message }, 403);
    return reply({ fee_account_id: data });
  }

  if (action === "admin-assign-principal-approver") {
    const userId = typeof input.user_id === "string" ? input.user_id : "";
    const enabled = input.enabled !== false;
    if (!UUID_RE.test(userId)) return reply({ error: "A valid Principal user ID is required" }, 400);
    const { error } = await userClient.rpc("fee_admin_assign_principal_approver", { p_user_id: userId, p_enabled: enabled });
    if (error) return reply({ error: error.message }, 403);
    return reply({ status: enabled ? "PRINCIPAL_ENABLED" : "PRINCIPAL_DISABLED" });
  }

  if (action === "admin-create-discount-request") {
    const accountId = typeof input.fee_account_id === "string" ? input.fee_account_id : "";
    const amountPaise = Number(input.amount_paise);
    const reason = typeof input.reason === "string" ? input.reason.trim() : "";
    if (!UUID_RE.test(accountId) || !Number.isSafeInteger(amountPaise) || amountPaise <= 0 || reason.length < 3 || reason.length > 1000) {
      return reply({ error: "Valid fee account, discount amount and reason are required" }, 400);
    }
    const { data, error } = await userClient.rpc("fee_admin_create_discount_request", { p_fee_account_id: accountId, p_amount_paise: amountPaise, p_reason: reason });
    if (error) return reply({ error: error.message }, 403);
    return reply({ discount_request_id: data, status: "PENDING_REVIEW" });
  }

  if (action === "admin-review-discount") {
    const discountId = typeof input.discount_id === "string" ? input.discount_id : "";
    if (!UUID_RE.test(discountId) || typeof input.approve !== "boolean") return reply({ error: "Invalid discount review request" }, 400);
    const { data, error } = await userClient.rpc("fee_admin_review_discount", {
      p_discount_id: discountId,
      p_approve: input.approve,
      p_reason: typeof input.reason === "string" ? input.reason : null,
    });
    if (error) return reply({ error: error.message }, 403);
    return reply({ status: data });
  }

  if (action === "create-proof-download") {
    const submissionId = typeof input.submission_id === "string" ? input.submission_id : "";
    if (!UUID_RE.test(submissionId)) return reply({ error: "Invalid submission ID" }, 400);
    // Only return a signed proof URL if this caller can see the corresponding review queue.
    const { data: adminRows } = await userClient.rpc("fee_admin_payment_queue");
    let allowedRow = Array.isArray(adminRows) ? adminRows.find((row: { submission_id?: string }) => row.submission_id === submissionId) : null;
    if (!allowedRow) {
      const { data: principalRows } = await userClient.rpc("fee_principal_payment_queue");
      allowedRow = Array.isArray(principalRows) ? principalRows.find((row: { submission_id?: string }) => row.submission_id === submissionId) : null;
    }
    if (!allowedRow || typeof allowedRow.proof_object_path !== "string") {
      return reply({ error: "Proof is not available to this reviewer or the submission is no longer pending" }, 403);
    }
    const { data, error } = await adminClient.storage.from("fee-payment-proofs")
      .createSignedUrl(allowedRow.proof_object_path, 90);
    if (error || !data?.signedUrl) return reply({ error: "Unable to create private proof link" }, 500);
    return reply({ signed_url: data.signedUrl, expires_in_seconds: 90 });
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
