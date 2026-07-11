import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/**
 * lead-intake — creación de leads en tiempo real desde otros sistemas de
 * Appril (hoy: el agente de ventas del DM de Instagram/Messenger, que vive
 * en el Supabase del PRODUCTO). Cierra la deuda de "lead-intake firmado"
 * anotada en DEC-019.
 *
 * Seguridad: FAIL-CLOSED con HMAC-SHA256 del raw body en `x-appril-signature`
 * (formato sha256=<hex>), secret compartido CRM_FORWARD_SECRET — el mismo de
 * la frontera producto→CRM del router de WhatsApp (Fase A). Sin secret
 * configurado o sin firma válida: 401.
 *
 * Body: { source: string, channel?: string, full_name?: string,
 *         external_ref?: string }   (external_ref = id de la conversación
 *         del canal en el producto, para trazabilidad en metadata)
 * Respuesta: { ok: true, lead_id, dl_token } — el dl_token viaja en el link
 * de registro (?dl=) y la plomería EXISTENTE de DEC-018 (signup-callback)
 * sella account_created cuando la cuenta se crea de verdad.
 */

const WORKSPACE_ID = "e2096477-fa6a-4b8f-a8b3-bd46ad720167";
const ALLOWED_SOURCES = new Set(["instagram_dm", "messenger_dm"]);

async function verifySignature(rawBody: string, header: string | null, secret: string): Promise<boolean> {
  if (!header?.startsWith("sha256=")) return false;
  const expected = header.slice(7).toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(expected)) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody)));
  const actual = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (actual.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < actual.length; i++) diff |= actual.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "GET") {
    const url = new URL(req.url);
    if (url.searchParams.get("health") === "1") {
      return json(200, { ok: !!Deno.env.get("CRM_FORWARD_SECRET"), agent: "lead_intake" });
    }
    return json(405, { error: "Method not allowed" });
  }
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const secret = Deno.env.get("CRM_FORWARD_SECRET");
  if (!secret) {
    console.error("[lead-intake] CRM_FORWARD_SECRET no configurado — rechazado");
    return json(401, { error: "unauthorized" });
  }
  const rawBody = await req.text();
  const valid = await verifySignature(rawBody, req.headers.get("x-appril-signature"), secret);
  if (!valid) return json(401, { error: "unauthorized" });

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return json(400, { error: "invalid json" });
  }

  const source = String(body.source ?? "");
  if (!ALLOWED_SOURCES.has(source)) return json(400, { error: "source no permitido" });
  const fullName = body.full_name ? String(body.full_name).slice(0, 120) : null;
  const externalRef = body.external_ref ? String(body.external_ref).slice(0, 80) : null;
  const channel = body.channel ? String(body.channel).slice(0, 20) : null;

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: lead, error } = await sb
    .from("leads_master")
    .insert({
      workspace_id: WORKSPACE_ID,
      source,
      full_name: fullName,
    })
    .select("id, dl_token, workspace_id")
    .single();

  if (error || !lead) {
    console.error("[lead-intake] insert failed", error);
    return json(500, { error: "insert failed" });
  }

  // Evento de timeline: el lead nació en un DM de la marca.
  await sb.from("lead_events").insert({
    workspace_id: lead.workspace_id,
    lead_id: lead.id,
    event_type: "dm_lead_created",
    event_channel: channel ?? "instagram",
    event_value: source,
    metadata: { external_ref: externalRef, source },
  });

  return json(200, { ok: true, lead_id: lead.id, dl_token: lead.dl_token });
});
