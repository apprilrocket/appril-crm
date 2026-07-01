// Appril — email-unsubscribe (List-Unsubscribe one-click, RFC 8058)
// Endpoint HTTPS público de baja de email. Identifica al lead por el token
// opaco `dl` (leads_master.dl_token), NO por lead_id.
//
//   POST .../email-unsubscribe?dl=<token>   → da de baja (one-click). Lo usa el
//                                             cliente de correo con el header
//                                             List-Unsubscribe-Post.
//   GET  .../email-unsubscribe?dl=<token>   → página de confirmación con botón
//                                             que hace POST. GET NUNCA da de baja
//                                             (evita que el prefetch/escáner del
//                                             correo cancele suscripciones solo).
//
// Idempotente. Respuesta genérica: no revela si el token existe (anti-enumeración).
// Requiere deploy con verify_jwt=false (ver supabase/config.toml).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const DL_RE = /^[a-f0-9]{32}$/i; // uuid sin guiones

function htmlPage(title: string, message: string, form?: string): string {
  return `<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${title}</title></head>
<body style="margin:0;background:#f8fafc;font-family:-apple-system,Segoe UI,Arial,sans-serif;color:#1f2937;">
<table width="100%" cellpadding="0" cellspacing="0" style="padding:48px 16px;"><tr><td align="center">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#fff;border:1px solid #e5e7eb;border-radius:14px;">
<tr><td style="padding:28px;">
<p style="margin:0 0 16px;font-size:22px;font-weight:700;color:#F45B69;">Appril</p>
<h1 style="margin:0 0 12px;font-size:19px;color:#0f172a;">${title}</h1>
<p style="margin:0 0 20px;font-size:15px;line-height:1.6;color:#334155;">${message}</p>
${form ?? ""}
</td></tr></table></td></tr></table></body></html>`;
}

function htmlResponse(status: number, body: string): Response {
  return new Response(body, { status, headers: { ...CORS, "Content-Type": "text/html; charset=utf-8" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  const dl = (url.searchParams.get("dl") ?? "").trim();

  // GET → página de confirmación (no da de baja). Evita prefetch/escáner.
  if (req.method === "GET") {
    if (!DL_RE.test(dl)) {
      return htmlResponse(200, htmlPage(
        "Enlace inválido",
        "Este enlace de baja no es válido o ya expiró. Si quiere cancelar su suscripción, responda a cualquiera de nuestros correos.",
      ));
    }
    const form = `<form method="POST" action="?dl=${encodeURIComponent(dl)}" style="margin:0;">
<input type="hidden" name="List-Unsubscribe" value="One-Click">
<button type="submit" style="background:#F45B69;color:#fff;border:0;padding:13px 22px;border-radius:8px;font-size:15px;font-weight:700;cursor:pointer;">Sí, cancelar suscripción</button>
</form>`;
    return htmlResponse(200, htmlPage(
      "¿Cancelar suscripción?",
      "Dejará de recibir correos de Appril. Puede confirmarlo aquí:",
      form,
    ));
  }

  if (req.method !== "POST") {
    return htmlResponse(405, htmlPage("Método no permitido", "Use GET o POST."));
  }

  // POST → baja (one-click). Respuesta genérica siempre (anti-enumeración).
  const DONE = htmlResponse(200, htmlPage(
    "Listo",
    "Su suscripción fue cancelada. No volverá a recibir correos de Appril. Gracias.",
  ));

  if (!DL_RE.test(dl)) return DONE;

  try {
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: lead } = await sb
      .from("leads_master")
      .select("id, workspace_id, unsubscribed_email")
      .eq("dl_token", dl)
      .maybeSingle();

    if (lead && lead.unsubscribed_email !== true) {
      await sb
        .from("leads_master")
        .update({ unsubscribed_email: true, can_email: false, updated_at: new Date().toISOString() })
        .eq("id", lead.id);

      await sb.from("lead_events").insert({
        workspace_id: lead.workspace_id,
        lead_id: lead.id,
        event_type: "email_unsubscribed",
        event_channel: "email",
        event_value: "list_unsubscribe",
        metadata: { source: "one_click", method: req.method },
      });
    }
    // Si no se encontró o ya estaba dado de baja: misma respuesta genérica.
    return DONE;
  } catch (err) {
    console.error("email-unsubscribe error:", err instanceof Error ? err.message : String(err));
    // Aun en error, no exponemos detalle; el cliente de correo solo necesita 200.
    return DONE;
  }
});
