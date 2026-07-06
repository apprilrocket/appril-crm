// Appril CRM — Inbox send
// Envía una respuesta manual desde el inbox del dashboard, al instante.
// WhatsApp: texto libre (válido dentro de la ventana de 24h de Meta).
// Email: SES directo.
// Registra el evento en lead_events para que la conversación (y el agente IA) tengan el contexto.
// v2: valida E.164 estricto antes de llamar a Meta — nunca se adivina el país.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SESv2Client, SendEmailCommand } from "https://esm.sh/@aws-sdk/client-sesv2@3";

const WA_ACCESS_TOKEN = Deno.env.get("WA_ACCESS_TOKEN")!;
const WA_PHONE_ID = Deno.env.get("WA_PHONE_NUMBER_ID")!;
const WA_API_VERSION = Deno.env.get("WA_API_VERSION") ?? "v25.0";
// Remitente unificado: todo Appril sale de hola@appril.co (envía y recibe).
const FROM_EMAIL = Deno.env.get("INBOX_FROM_EMAIL") ?? "Appril <hola@appril.co>";
// Workspace que puede usar las credenciales env como fallback (Appril).
// Otros workspaces deben tener su integración configurada — anti-fuga entre tenants.
const DEFAULT_WORKSPACE_ID = Deno.env.get("DEFAULT_WORKSPACE_ID") ?? "";

type ChannelCreds = {
  emailFrom: string | null;
  waPhoneId: string | null;
  waToken: string | null;
};

// Resuelve credenciales del workspace; null en un campo = no configurado.
async function loadChannels(sb: ReturnType<typeof createClient>, workspaceId: string): Promise<ChannelCreds> {
  const [{ data: integrations }, { data: secret }] = await Promise.all([
    sb.from("workspace_integrations")
      .select("channel, status, from_email, from_name, wa_phone_number_id")
      .eq("workspace_id", workspaceId)
      .eq("status", "active"),
    sb.from("workspace_secrets")
      .select("value")
      .eq("workspace_id", workspaceId)
      .eq("key", "wa_access_token")
      .maybeSingle(),
  ]);

  const email = (integrations ?? []).find((i: any) => i.channel === "email" && i.from_email);
  const wa = (integrations ?? []).find((i: any) => i.channel === "whatsapp" && i.wa_phone_number_id);

  return {
    emailFrom: email ? (email.from_name ? `${email.from_name} <${email.from_email}>` : email.from_email) : null,
    waPhoneId: wa?.wa_phone_number_id ?? null,
    waToken: secret?.value ?? null,
  };
}

const E164 = /^\+[1-9][0-9]{7,14}$/;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { ok: false, error: "method not allowed" });

  try {
    const { lead_id, channel, text, subject } = await req.json();
    if (!lead_id || !text?.trim()) return json(400, { ok: false, error: "lead_id y text son requeridos" });
    if (channel !== "whatsapp" && channel !== "email") return json(400, { ok: false, error: "channel inválido" });

    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data: lead, error: leadErr } = await sb
      .from("leads_master")
      .select("id, workspace_id, full_name, phone, email, can_email, can_whatsapp")
      .eq("id", lead_id)
      .single();

    if (leadErr || !lead) return json(404, { ok: false, error: "lead no encontrado" });

    const ch = await loadChannels(sb, lead.workspace_id);
    const isDefaultWs = !DEFAULT_WORKSPACE_ID || lead.workspace_id === DEFAULT_WORKSPACE_ID;

    if (channel === "whatsapp") {
      if (!lead.phone) return json(400, { ok: false, error: "el lead no tiene teléfono" });
      if (!E164.test(String(lead.phone))) {
        return json(422, { ok: false, error: `teléfono inválido (debe ser E.164 con indicativo, ej +573001234567): "${lead.phone}". Corrígelo en el perfil del lead.` });
      }
      if (lead.can_whatsapp === false) {
        return json(422, { ok: false, error: "el lead tiene can_whatsapp=false (opt-out o número sin WhatsApp)" });
      }

      // Ventana de servicio de 24h de Meta: el texto libre solo es válido dentro
      // de las 24h desde el último mensaje ENTRANTE del lead. Fuera de la ventana
      // Meta rechaza; validamos ANTES de llamar para dar un error accionable y no
      // depender del rechazo remoto (doble candado con la UI).
      const { data: lastIn } = await sb
        .from("lead_events")
        .select("created_at")
        .eq("lead_id", lead.id)
        .eq("event_type", "wa_reply")
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      const lastInboundMs = lastIn?.created_at ? new Date(lastIn.created_at as string).getTime() : 0;
      const windowOpen = lastInboundMs > 0 && (Date.now() - lastInboundMs) < 24 * 60 * 60 * 1000;
      if (!windowOpen) {
        return json(422, {
          ok: false,
          code: "window_closed",
          error: "Estás fuera de la ventana de envío libre de mensajes (24h de Meta). Solo puedes enviar templates a este lead.",
        });
      }

      const to = String(lead.phone).replace(/^\+/, "");

      const waPhoneId = ch.waPhoneId ?? (isDefaultWs ? WA_PHONE_ID : null);
      const waToken = ch.waToken ?? (isDefaultWs ? WA_ACCESS_TOKEN : null);
      if (!waPhoneId || !waToken) {
        return json(422, { ok: false, error: "este workspace no tiene WhatsApp configurado (Settings → Integraciones)" });
      }

      const res = await fetch(`https://graph.facebook.com/${WA_API_VERSION}/${waPhoneId}/messages`, {
        method: "POST",
        headers: { Authorization: `Bearer ${waToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          to,
          type: "text",
          text: { body: text, preview_url: true },
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        const msg = data?.error?.message ?? `HTTP ${res.status}`;
        // Error típico fuera de la ventana de 24h → mensaje claro para el UI
        return json(422, { ok: false, error: msg });
      }

      // wa_agent_reply con manual:true → visible en la conversación y en el historial del agente IA
      await sb.from("lead_events").insert({
        workspace_id: lead.workspace_id,
        lead_id: lead.id,
        event_type: "wa_agent_reply",
        event_channel: "whatsapp",
        event_value: text,
        metadata: { manual: "true", by: "inbox", wa_message_id: data?.messages?.[0]?.id ?? null },
      });
    } else {
      if (!lead.email) return json(400, { ok: false, error: "el lead no tiene email" });
      if (lead.can_email === false) return json(422, { ok: false, error: "el lead tiene can_email=false (bounce o unsubscribe)" });

      const fromEmail = ch.emailFrom ?? (isDefaultWs ? FROM_EMAIL : null);
      if (!fromEmail) {
        return json(422, { ok: false, error: "este workspace no tiene email configurado (Settings → Integraciones)" });
      }

      const ses = new SESv2Client({
        region: Deno.env.get("AWS_REGION") || "us-east-1",
        credentials: {
          accessKeyId: Deno.env.get("AWS_SES_ACCESS_KEY_ID")!,
          secretAccessKey: Deno.env.get("AWS_SES_SECRET_ACCESS_KEY")!,
        },
      });

      const htmlBody = text
        .split(/\n{2,}/)
        .map((p: string) => `<p style="margin:0 0 14px;font-size:15px;color:#222;line-height:1.6;">${p.replace(/\n/g, "<br>")}</p>`)
        .join("");

      await ses.send(new SendEmailCommand({
        FromEmailAddress: fromEmail,
        Destination: { ToAddresses: [lead.email as string] },
        Content: {
          Simple: {
            Subject: { Data: subject?.trim() || "Re: Appril", Charset: "UTF-8" },
            Body: {
              Html: { Data: `<div style="font-family:-apple-system,Segoe UI,Arial,sans-serif;max-width:600px;">${htmlBody}</div>`, Charset: "UTF-8" },
              Text: { Data: text, Charset: "UTF-8" },
            },
          },
        },
      }));

      await sb.from("lead_events").insert({
        workspace_id: lead.workspace_id,
        lead_id: lead.id,
        event_type: "manual_reply",
        event_channel: "email",
        event_value: subject?.trim() ? `${subject.trim()} — ${text}` : text,
        metadata: { manual: "true", by: "inbox" },
      });
    }

    await sb.from("leads_master").update({
      last_contacted_at: new Date().toISOString(),
      last_channel_touched: channel,
      inbox_read_at: new Date().toISOString(),
    }).eq("id", lead.id);

    return json(200, { ok: true });
  } catch (err) {
    console.error("inbox-send error:", err);
    return json(500, { ok: false, error: String(err) });
  }
});
