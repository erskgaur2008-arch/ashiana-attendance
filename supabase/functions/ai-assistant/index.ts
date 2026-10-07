import { createSupabaseContext } from "npm:@supabase/server@1";

const PRIMARY_MODEL = "gemini-3.8-flash";
const FALLBACK_MODEL = "gemini-3.7-flash";
const LAST_RESORT_MODEL = "gemini-3.5-flash-lite";
const MAX_INPUT_CHARS = 4000;
const MAX_OUTPUT_TOKENS = 800;

// Keep each provider attempt short so a transient Gemini outage does not
// leave the Staff/Teacher UI stuck on "Thinking..." for a long time.
const GEMINI_TIMEOUT_MS = 7000;
const MAX_RETRY_ATTEMPTS = 1;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function wait(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isTransientStatus(status?: number) {
  return status === 408 || status === 429 || (status !== undefined && status >= 500 && status <= 599);
}

function backoffDelay(attempt: number) {
  const base = 500 * (2 ** attempt);
  return base + Math.floor(Math.random() * 400);
}

async function requestGemini(
  model: string,
  apiKey: string,
  prompt: string,
  useThinking = true,
): Promise<{ response?: Response; timedOut?: boolean }> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), GEMINI_TIMEOUT_MS);

  try {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": apiKey,
        },
        body: JSON.stringify({
          contents: [{ role: "user", parts: [{ text: prompt }] }],
          generationConfig: {
            maxOutputTokens: MAX_OUTPUT_TOKENS,
            ...(useThinking ? { thinkingConfig: { thinkingLevel: "low" } } : {}),
          },
        }),
        signal: controller.signal,
      },
    );

    return { response };
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      return { timedOut: true };
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}

async function requestWithRetry(
  model: string,
  apiKey: string,
  prompt: string,
  useThinking = true,
) {
  for (let attempt = 0; attempt <= MAX_RETRY_ATTEMPTS; attempt += 1) {
    const result = await requestGemini(model, apiKey, prompt, useThinking);

    if (!result.timedOut && !isTransientStatus(result.response?.status)) {
      return result;
    }

    if (attempt < MAX_RETRY_ATTEMPTS) {
      console.error(`Gemini ${model} transient failure; retrying with backoff`);
      await wait(backoffDelay(attempt));
    }
  }

  return {
    ...(await requestGemini(model, apiKey, prompt, useThinking)),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const { data: ctx, error: authError } = await createSupabaseContext(req, { auth: "user" });
  if (authError || !ctx?.userClaims) {
    return json({ error: "AUTH_REQUIRED" }, 401);
  }

  const apiKey = Deno.env.get("GEMINI_API_KEY")?.trim();
  if (!apiKey) {
    return json({ error: "AI_NOT_CONFIGURED", message: "Gemini API key is not configured on the server." }, 503);
  }

  let body: { message?: unknown } = {};
  try {
    body = await req.json();
  } catch {
    return json({ error: "INVALID_JSON" }, 400);
  }

  const message = String(body.message ?? "").trim();
  if (!message) return json({ error: "MESSAGE_REQUIRED" }, 400);
  if (message.length > MAX_INPUT_CHARS) {
    return json({ error: "MESSAGE_TOO_LONG", message: `Please keep your question under ${MAX_INPUT_CHARS} characters.` }, 400);
  }

  const prompt = [
    "You are the Ashiana Public School AI Assistant.",
    "Help students, teachers, and administrators with general school, homework, study, writing, and productivity questions.",
    "Be concise, clear, safe, and age-appropriate.",
    "Do not claim access to school databases, attendance, marks, notices, homework records, or private student information unless that information is explicitly provided in the current message.",
    "Never request or encourage users to share passwords, PINs, admission numbers, DOBs, phone numbers, addresses, or other sensitive personal information.",
    "For medical, legal, financial, or other high-stakes questions, provide general information and recommend a qualified professional.",
    "",
    "User question:",
    message,
  ].join("\n");

  try {
    let selectedModel = PRIMARY_MODEL;
    let result = await requestWithRetry(PRIMARY_MODEL, apiKey, prompt);

    if (result.timedOut || isTransientStatus(result.response?.status)) {
      selectedModel = FALLBACK_MODEL;
      console.error(`Gemini ${PRIMARY_MODEL} unavailable after bounded retry; trying ${FALLBACK_MODEL}`);
      await wait(backoffDelay(1));
      result = await requestWithRetry(FALLBACK_MODEL, apiKey, prompt, false);
    }

    if (result.timedOut || isTransientStatus(result.response?.status)) {
      selectedModel = LAST_RESORT_MODEL;
      console.error(`Gemini ${FALLBACK_MODEL} unavailable; trying ${LAST_RESORT_MODEL}`);
      await wait(backoffDelay(2));
      result = await requestGemini(LAST_RESORT_MODEL, apiKey, prompt, false);
    }

    if (result.timedOut) {
      return json(
        { error: "AI_TIMEOUT", message: "The AI service is temporarily busy. Please try again in a moment." },
        504,
      );
    }

    const response = result.response;
    if (!response) {
      return json({ error: "AI_REQUEST_FAILED", message: "AI service is temporarily unavailable." }, 502);
    }

    const data = await response.json();
    if (!response.ok) {
      console.error(
        "Gemini request failed:",
        selectedModel,
        response.status,
        data?.error?.status || data?.error?.message,
      );
      return json(
        { error: "AI_PROVIDER_ERROR", message: "The AI service is temporarily busy. Please try again in a moment." },
        502,
      );
    }

    const answer = data?.candidates?.[0]?.content?.parts
      ?.map((part: { text?: string }) => part?.text || "")
      .join("")
      .trim();

    if (!answer) return json({ error: "EMPTY_AI_RESPONSE" }, 502);
    return json({ answer, model: selectedModel });
  } catch (error) {
    console.error("Gemini function error:", error instanceof Error ? error.message : String(error));
    return json({ error: "AI_REQUEST_FAILED", message: "AI service is temporarily unavailable." }, 502);
  }
});
