import { createSupabaseContext } from "npm:@supabase/server@1";

const MODEL = "gemini-3.8-flash";
const MAX_INPUT_CHARS = 4000;
const MAX_OUTPUT_TOKENS = 800;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
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
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": apiKey,
        },
        body: JSON.stringify({
          contents: [{ role: "user", parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0.4,
            maxOutputTokens: MAX_OUTPUT_TOKENS,
          },
        }),
      },
    );

    const data = await response.json();
    if (!response.ok) {
      console.error("Gemini request failed:", response.status, data?.error?.status || data?.error?.message);
      return json({ error: "AI_PROVIDER_ERROR", message: "Gemini could not answer right now. Please try again." }, 502);
    }

    const answer = data?.candidates?.[0]?.content?.parts
      ?.map((part: { text?: string }) => part?.text || "")
      .join("")
      .trim();

    if (!answer) return json({ error: "EMPTY_AI_RESPONSE" }, 502);
    return json({ answer, model: MODEL });
  } catch (error) {
    console.error("Gemini function error:", error instanceof Error ? error.message : String(error));
    return json({ error: "AI_REQUEST_FAILED", message: "AI service is temporarily unavailable." }, 502);
  }
});
