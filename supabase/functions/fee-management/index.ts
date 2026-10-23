import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const corsBase = {
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};

function reply(body: unknown, status = 200, headers: Record<string, string> = corsBase) {
  return new Response(JSON.stringify(body), { status, headers });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "image/webp", "application/pdf"]);
const MAX_BYTES = 5 * 1024 * 1024;

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin");
  const allowedOrigins = (Deno.env.get("FEE_ALLOWED_ORIGINS") ?? "")
    .split(",").map((value) => value.trim()).filter(Boolean);
  const corsHeaders: Record<string, string> = { ...corsBase };
  if (origin && allowedOrigins.includes(origin)) corsHeaders["Access-Control-Allow-Origin"] = origin;
  const respond = (body: unknown, status = 200) => reply(body, status, corsHeaders);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return respond({ error: "Server configuration unavailable" }, 500);

  const authHeader = req.headers.get("Authorization");
  let input: Record<string, unknown>;
  try {
    input = await req.json();
  } catch {
    return respond({ error: "Invalid JSON body" }, 400);
  }
  const action = input.action;
  const studentActions = new Set([
    "create-proof-upload", "student-summary", "discard-proof-upload",
    "submit-payment", "student-submissions", "student-receipts",
  ]);
  if (!authHeader?.startsWith("Bearer ") && !studentActions.has(String(action))) {
    return respond({ error: "Authorization required" }, 401);
  }
  const userClient = createClient(url, anonKey, {
    ...(authHeader?.startsWith("Bearer ") ? { global: { headers: { Authorization: authHeader } } } : {}),
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const adminClient = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  if (action === "create-proof-upload") {
    // Student portal bearer tokens are custom session tokens, not Supabase Auth JWTs.
    // They must be passed in student_session_token and validated by the dedicated RPC.
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    const accountId = typeof input.fee_account_id === "string" ? input.fee_account_id : "";
    const fileName = typeof input.file_name === "string" ? input.file_name : "";
    const contentType = typeof input.content_type === "string" ? input.content_type : "";
    const size = Number(input.size_bytes);
    if (token.length < 32 || token.length > 256 || !UUID_RE.test(accountId)) {
      return respond({ error: "Invalid student session or fee account" }, 400);
    }
    if (!ALLOWED_TYPES.has(contentType) || !Number.isInteger(size) || size <= 0 || size > MAX_BYTES) {
      return respond({ error: "Unsupported file type or file exceeds 5 MB" }, 400);
    }
    const safeName = fileName.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-80) || "proof";
    const { data: summary, error: summaryError } = await adminClient.rpc("fee_student_summary_by_session", { p_token: token });
    if (summaryError || !Array.isArray(summary) || !summary.some((row: { fee_account_id?: string }) => row.fee_account_id === accountId)) {
      return respond({ error: "Fee account not available for this student session" }, 403);
    }
    // Object path is generated server-side and is not exposed as a public URL.
    const objectPath = `${accountId}/${crypto.randomUUID()}-${safeName}`;
    const { data, error } = await adminClient.storage.from("fee-payment-proofs").createSignedUploadUrl(objectPath, { upsert: false });
    if (error || !data?.signedUrl || !data?.token) {
      return respond({ error: "Unable to prepare private upload" }, 500);
    }
    return respond({ object_path: objectPath, signed_url: data.signedUrl, upload_token: data.token, content_type: contentType, expires_in_seconds: 120 });
  }

  if (action === "student-summary") {
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    if (token.length < 32 || token.length > 256) return respond({ error: "Invalid student session" }, 400);
    const { data, error } = await adminClient.rpc("fee_student_summary_by_session", { p_token: token });
    if (error) return respond({ error: "Unable to load fee summary" }, 403);
    return respond({ accounts: data ?? [] });
  }

  if (action === "discard-proof-upload") {
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    const accountId = typeof input.fee_account_id === "string" ? input.fee_account_id : "";
    const objectPath = typeof input.proof_object_path === "string" ? input.proof_object_path : "";
    if (token.length < 32 || token.length > 256 || !UUID_RE.test(accountId) ||
        !objectPath.startsWith(accountId + "/") || objectPath.includes("..") || objectPath.startsWith("/")) {
      return respond({ error: "Invalid proof cleanup request" }, 400);
    }
    const { data: summary, error: summaryError } = await adminClient.rpc("fee_student_summary_by_session", { p_token: token });
    if (summaryError || !Array.isArray(summary) || !summary.some((row: { fee_account_id?: string }) => row.fee_account_id === accountId)) {
      return respond({ error: "Fee account not available for this student session" }, 403);
    }
    const { data: linked, error: linkedError } = await adminClient.from("fee_payment_submissions")
      .select("id").eq("fee_account_id", accountId).eq("proof_object_path", objectPath).limit(1);
    if (linkedError) return respond({ error: "Unable to verify proof ownership for cleanup" }, 500);
    if (linked?.length) return respond({ status: "retained_for_payment_review" });
    const { error: removeError } = await adminClient.storage.from("fee-payment-proofs").remove([objectPath]);
    if (removeError) return respond({ error: "Unable to clean up unused proof upload" }, 500);
    return respond({ status: "unused_proof_removed" });
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
      return respond({ error: "Invalid payment submission details" }, 400);
    }
    const { data: summary, error: summaryError } = await adminClient.rpc("fee_student_summary_by_session", { p_token: token });
    if (summaryError || !Array.isArray(summary) || !summary.some((row: { fee_account_id?: string }) => row.fee_account_id === accountId)) {
      return respond({ error: "Fee account not available for this student session" }, 403);
    }
    const { data: objects, error: objectError } = await adminClient.storage.from("fee-payment-proofs").list(accountId, {
      search: objectPath.slice(accountId.length + 1),
      limit: 10,
    });
    const objectName = objectPath.slice(accountId.length + 1);
    const uploadedObject = objects?.find((obj: { name: string }) => obj.name === objectName) as
      | { name: string; metadata?: Record<string, unknown> | null }
      | undefined;
    if (objectError || !uploadedObject) {
      return respond({ error: "Upload the required payment screenshot before submitting" }, 400);
    }
    // Validate the stored object metadata as well as the browser-declared MIME/size.
    const metadata = uploadedObject.metadata ?? {};
    const storedMime = String(metadata.mimetype ?? metadata.contentType ?? "");
    const storedSize = Number(metadata.size ?? metadata.contentLength ?? 0);
    if (!ALLOWED_TYPES.has(storedMime) || !Number.isFinite(storedSize) || storedSize <= 0 || storedSize > MAX_BYTES) {
      await adminClient.storage.from("fee-payment-proofs").remove([objectPath]);
      return respond({ error: "Stored proof has an unsupported content type or size" }, 400);
    }
    const { data, error } = await adminClient.rpc("fee_submit_payment_by_session", {
      p_token: token,
      p_fee_account_id: accountId,
      p_amount_paise: amount,
      p_upi_reference: reference,
      p_proof_object_path: objectPath,
      p_student_note: typeof input.student_note === "string" ? input.student_note.slice(0, 1000) : null,
    });
    if (error) return respond({ error: error.message }, 400);
    return respond({ submission_id: data, status: "PENDING_ADMIN" }, 201);
  }

  if (action === "student-submissions") {
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    if (token.length < 32 || token.length > 256) return respond({ error: "Invalid student session" }, 400);
    const { data, error } = await adminClient.rpc("fee_student_submissions_by_session", { p_token: token });
    if (error) return respond({ error: "Unable to load payment status" }, 403);
    return respond({ submissions: data ?? [] });
  }

  if (action === "student-receipts") {
    const token = typeof input.student_session_token === "string" ? input.student_session_token : "";
    if (token.length < 32 || token.length > 256) return respond({ error: "Invalid student session" }, 400);
    const { data, error } = await adminClient.rpc("fee_student_receipts_by_session", { p_token: token });
    if (error) return respond({ error: "Unable to load receipts" }, 403);
    return respond({ receipts: data ?? [] });
  }

  if (action === "admin-queue" || action === "principal-queue") {
    // Authorization is enforced inside the corresponding SECURITY DEFINER RPC.
    const rpcName = action === "admin-queue" ? "fee_admin_payment_queue" : "fee_principal_payment_queue";
    const { data, error } = await userClient.rpc(rpcName);
    if (error) return respond({ error: error.message }, 403);
    return respond({ submissions: data ?? [] });
  }

  if (action === "admin-list-years") {
    const { data, error } = await userClient.rpc("fee_admin_list_academic_years");
    if (error) return respond({ error: error.message }, 403);
    return respond({ academic_years: data ?? [] });
  }

  if (action === "admin-search-students-page") {
    const query = typeof input.query === "string" ? input.query : "";
    const limit = Math.max(1, Math.min(100, Number(input.limit) || 50));
    const offset = Math.max(0, Number(input.offset) || 0);
    const { data, error } = await userClient.rpc("fee_admin_search_students_page", {
      p_query: query, p_limit: limit, p_offset: offset,
    });
    if (error) return respond({ error: error.message || "Unable to search students" }, 403);
    return respond({ students: data ?? [], limit, offset, has_more: (data?.length ?? 0) === limit });
  }

  if (action === "admin-search-students") {
    const query = typeof input.query === "string" ? input.query.trim().slice(0, 80) : "";
    const { data, error } = await userClient.rpc("fee_admin_search_students", { p_query: query });
    if (error) return respond({ error: error.message }, 403);
    return respond({ students: data ?? [] });
  }

  if (action === "admin-search-fee-accounts") {
    const query = typeof input.query === "string" ? input.query.trim().slice(0, 80) : "";
    const { data, error } = await userClient.rpc("fee_admin_search_fee_accounts", { p_query: query });
    if (error) return respond({ error: error.message }, 403);
    return respond({ fee_accounts: data ?? [] });
  }

  if (action === "admin-list-structures") {
    const yearId = typeof input.academic_year_id === "string" ? input.academic_year_id : "";
    const className = typeof input.class_name === "string" ? input.class_name.trim() : "";
    if (!UUID_RE.test(yearId)) return respond({ error: "Valid academic year is required" }, 400);
    const { data: years, error: permissionError } = await userClient.rpc("fee_admin_list_academic_years");
    if (permissionError || !Array.isArray(years) || !years.some((row: { id?: string }) => row.id === yearId)) {
      return respond({ error: "Admin permission required or academic year unavailable" }, 403);
    }
    let query = adminClient.from("fee_structures").select("id,class_name,fee_name,amount_paise,is_mandatory,due_date").eq("school_code","ashiana").eq("academic_year_id",yearId).order("class_name").order("fee_name").limit(300);
    if (className) query = query.eq("class_name",className);
    const { data, error } = await query;
    if (error) return respond({ error: "Unable to load fee structures" }, 500);
    return respond({ fee_structures: data ?? [] });
  }

  if (action === "admin-save-academic-year") {
    const label = typeof input.label === "string" ? input.label.trim() : "";
    const startsOn = typeof input.starts_on === "string" ? input.starts_on : "";
    const endsOn = typeof input.ends_on === "string" ? input.ends_on : "";
    if (label.length < 4 || label.length > 40 || !/^\d{4}-\d{2}-\d{2}$/.test(startsOn) || !/^\d{4}-\d{2}-\d{2}$/.test(endsOn) || startsOn > endsOn || typeof input.is_active !== "boolean") {
      return respond({ error: "Provide a valid academic-year label and date range" }, 400);
    }
    const { data, error } = await userClient.rpc("fee_admin_save_academic_year", { p_label: label, p_starts_on: startsOn, p_ends_on: endsOn, p_is_active: input.is_active });
    if (error) return respond({ error: error.message }, 403);
    return respond({ academic_year_id: data });
  }

  if (action === "admin-save-structure") {
    const yearId = typeof input.academic_year_id === "string" ? input.academic_year_id : "";
    const className = typeof input.class_name === "string" ? input.class_name.trim() : "";
    const feeName = typeof input.fee_name === "string" ? input.fee_name.trim() : "";
    const amountPaise = Number(input.amount_paise);
    const dueDate = typeof input.due_date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(input.due_date) ? input.due_date : null;
    if (!UUID_RE.test(yearId) || !className || feeName.length < 2 || feeName.length > 100 || !Number.isSafeInteger(amountPaise) || amountPaise < 0 || typeof input.is_mandatory !== "boolean") {
      return respond({ error: "Provide a valid academic year, class, fee name and amount" }, 400);
    }
    const { data, error } = await userClient.rpc("fee_admin_save_structure", { p_academic_year_id: yearId, p_class_name: className, p_fee_name: feeName, p_amount_paise: amountPaise, p_is_mandatory: input.is_mandatory, p_due_date: dueDate });
    if (error) return respond({ error: error.message }, 403);
    return respond({ fee_structure_id: data });
  }

  if (action === "admin-assign-student-account") {
    const yearId = typeof input.academic_year_id === "string" ? input.academic_year_id : "";
    const studentId = typeof input.student_id === "string" ? input.student_id : "";
    if (!UUID_RE.test(yearId) || !UUID_RE.test(studentId)) return respond({ error: "Valid academic year and student IDs are required" }, 400);
    const { data, error } = await userClient.rpc("fee_admin_assign_student_account", { p_academic_year_id: yearId, p_student_id: studentId });
    if (error) return respond({ error: error.message }, 403);
    return respond({ fee_account_id: data });
  }

  if (action === "admin-assign-principal-approver") {
    const userId = typeof input.user_id === "string" ? input.user_id : "";
    const enabled = input.enabled !== false;
    if (!UUID_RE.test(userId)) return respond({ error: "A valid Principal user ID is required" }, 400);
    const { error } = await userClient.rpc("fee_admin_assign_principal_approver", { p_user_id: userId, p_enabled: enabled });
    if (error) return respond({ error: error.message }, 403);
    return respond({ status: enabled ? "PRINCIPAL_ENABLED" : "PRINCIPAL_DISABLED" });
  }

  if (action === "admin-create-discount-request") {
    const accountId = typeof input.fee_account_id === "string" ? input.fee_account_id : "";
    const amountPaise = Number(input.amount_paise);
    const reason = typeof input.reason === "string" ? input.reason.trim() : "";
    if (!UUID_RE.test(accountId) || !Number.isSafeInteger(amountPaise) || amountPaise <= 0 || reason.length < 3 || reason.length > 1000) {
      return respond({ error: "Valid fee account, discount amount and reason are required" }, 400);
    }
    const { data, error } = await userClient.rpc("fee_admin_create_discount_request", { p_fee_account_id: accountId, p_amount_paise: amountPaise, p_reason: reason });
    if (error) return respond({ error: error.message }, 403);
    return respond({ discount_request_id: data, status: "PENDING_REVIEW" });
  }

  if (action === "admin-discount-queue") {
    const { data, error } = await userClient.rpc("fee_admin_discount_queue");
    if (error) return respond({ error: error.message }, 403);
    return respond({ requests: data ?? [] });
  }

  if (action === "admin-review-discount") {
    const discountId = typeof input.discount_id === "string" ? input.discount_id : "";
    if (!UUID_RE.test(discountId) || typeof input.approve !== "boolean") return respond({ error: "Invalid discount review request" }, 400);
    const { data, error } = await userClient.rpc("fee_admin_review_discount", {
      p_discount_id: discountId,
      p_approve: input.approve,
      p_reason: typeof input.reason === "string" ? input.reason : null,
    });
    if (error) return respond({ error: error.message }, 403);
    return respond({ status: data });
  }

  if (action === "create-proof-download") {
    const submissionId = typeof input.submission_id === "string" ? input.submission_id : "";
    if (!UUID_RE.test(submissionId)) return respond({ error: "Invalid submission ID" }, 400);
    // Only return a signed proof URL if this caller can see the corresponding review queue.
    const { data: adminRows } = await userClient.rpc("fee_admin_payment_queue");
    let allowedRow = Array.isArray(adminRows) ? adminRows.find((row: { submission_id?: string }) => row.submission_id === submissionId) : null;
    if (!allowedRow) {
      const { data: principalRows } = await userClient.rpc("fee_principal_payment_queue");
      allowedRow = Array.isArray(principalRows) ? principalRows.find((row: { submission_id?: string }) => row.submission_id === submissionId) : null;
    }
    if (!allowedRow || typeof allowedRow.proof_object_path !== "string") {
      return respond({ error: "Proof is not available to this reviewer or the submission is no longer pending" }, 403);
    }
    const { data, error } = await adminClient.storage.from("fee-payment-proofs")
      .createSignedUrl(allowedRow.proof_object_path, 90);
    if (error || !data?.signedUrl) return respond({ error: "Unable to create private proof link" }, 500);
    return respond({ signed_url: data.signedUrl, expires_in_seconds: 90 });
  }

  if (action === "admin-review-payment") {
    const submissionId = typeof input.submission_id === "string" ? input.submission_id : "";
    if (!UUID_RE.test(submissionId) || typeof input.approve !== "boolean") return respond({ error: "Invalid review request" }, 400);
    const { data: result, error } = await userClient.rpc("fee_admin_review_payment", {
      p_submission_id: submissionId,
      p_approve: input.approve,
      p_reason: typeof input.reason === "string" ? input.reason : null,
    });
    if (error) return respond({ error: error.message }, 403);
    return respond({ status: result });
  }

  if (action === "principal-confirm-payment") {
    const submissionId = typeof input.submission_id === "string" ? input.submission_id : "";
    if (!UUID_RE.test(submissionId) || typeof input.confirm !== "boolean") return respond({ error: "Invalid confirmation request" }, 400);
    const { data: result, error } = await userClient.rpc("fee_principal_confirm_payment", {
      p_submission_id: submissionId,
      p_confirm: input.confirm,
      p_reason: typeof input.reason === "string" ? input.reason : null,
    });
    if (error) return respond({ error: error.message }, 403);
    return respond({ result });
  }

  return respond({ error: "Unsupported action" }, 400);
});
