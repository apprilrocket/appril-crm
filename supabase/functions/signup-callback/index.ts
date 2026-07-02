// Appril — signup-callback (cierre del loop lead → cuenta)
// El signup de app.appril.co lo invoca (fire-and-forget) cuando un usuario que
// llegó con el token opaco `dl` (leads_master.dl_token) completa la creación de
// cuenta (OTP verificado). Registra `account_created` en lead_events para que
// Growth/CRM puedan atribuir la cuenta a su lead y campaña.
//
//   POST .../signup-callback   body: { dl: string, email?: string }
//
// Idempotente (un solo account_created por lead). Respuesta genérica: no revela
// si el token existe (anti-enumeración). Requiere verify_jwt=false (config.toml).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DL_RE = /^[a-f0-9]{32}$/i; // uuid sin guiones (mismo formato que email-unsubscribe)

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { ok: false });

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json(400, { ok: false });
  }

  const dl = String(body?.dl ?? "").trim();
  const email = String(body?.email ?? "").trim().toLowerCase() || null;
  // Respuesta genérica ante token inválido/desconocido — no revelar existencia.
  if (!DL_RE.test(dl)) return json(200, { ok: true });

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: lead } = await sb
    .from("leads_master")
    .select("id, workspace_id")
    .eq("dl_token", dl)
    .maybeSingle();
  if (!lead) return json(200, { ok: true });

  // Idempotencia: un solo account_created por lead.
  const { data: prior } = await sb
    .from("lead_events")
    .select("id")
    .eq("lead_id", lead.id)
    .eq("event_type", "account_created")
    .limit(1);
  if (prior && prior.length > 0) return json(200, { ok: true });

  await sb.from("lead_events").insert({
    workspace_id: lead.workspace_id,
    lead_id: lead.id,
    event_type: "account_created",
    event_channel: "app",
    event_value: "signup_otp_verified",
    metadata: { source: "app_signup", signup_email: email },
  });

  return json(200, { ok: true });
});
