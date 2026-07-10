// Appril CRM — ses-webhook (Fase C de consolidación)
// Recibe los eventos de SES vía SNS. Reemplaza la ruta /webhook/ses del Lambda
// `appril-crm-webhook` (appril-sender/src/webhook.ts), replicando su semántica:
// correlación por ses_message_id, mismo mapa de eventos, misma metadata con
// atribución (campaign_id + template_key), mismos flags en leads_master.
//
// ENDURECIMIENTOS respecto del Lambda (que no validaba NADA):
//  · Firma SNS verificada criptográficamente contra el certificado de AWS.
//  · SubscribeURL/SigningCertURL restringidos a sns.<region>.amazonaws.com (anti-SSRF).
//  · TopicArn con allowlist opcional (SES_WEBHOOK_TOPIC_ARN).
//
// Modos (env SES_WEBHOOK_MODE): shadow (default) = valida, loguea y NO escribe;
// live = escribe. La confirmación de suscripción funciona en ambos modos.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isAwsUrl, verifySnsSignature } from "./sns.ts";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const MODE = Deno.env.get("SES_WEBHOOK_MODE") ?? "shadow";
const ALLOWED_TOPIC = Deno.env.get("SES_WEBHOOK_TOPIC_ARN") ?? "";

const EVENT_MAP: Record<string, string> = {
  Delivery: "email_delivered",
  Open: "email_opened",
  Click: "email_clicked",
  Bounce: "email_bounced",
  Complaint: "email_complained",
  Reject: "email_rejected",
};

async function handleNotification(msg: Record<string, any>, mode: string) {
  const message = JSON.parse(String(msg.Message ?? "{}"));
  const eventType: string = message.eventType ?? message.notificationType;
  const sesMessageId: string | undefined = message.mail?.messageId;
  if (!eventType || !sesMessageId) return { skipped: "sin eventType/messageId" };

  const { data: queue } = await sb
    .from("message_queue")
    .select("id, workspace_id, lead_id, campaign_id, template_key")
    .eq("ses_message_id", sesMessageId)
    .maybeSingle();
  if (!queue) return { skipped: `ses_message_id desconocido: ${sesMessageId}` };

  const internalType = EVENT_MAP[eventType] ?? `email_${eventType.toLowerCase()}`;

  if (mode === "shadow") {
    console.log(`[ses-webhook][shadow] ${eventType} → ${internalType} lead=${queue.lead_id} msg=${queue.id}`);
    return { shadow: true, eventType, internalType, lead_id: queue.lead_id };
  }

  await sb.from("lead_events").insert({
    workspace_id: queue.workspace_id,
    lead_id: queue.lead_id,
    event_type: internalType,
    event_channel: "email",
    event_value: eventType,
    metadata: { ...message, campaign_id: queue.campaign_id ?? null, template_key: queue.template_key ?? null },
  });

  if (eventType === "Open") {
    await sb.from("leads_master").update({ opened_email: true }).eq("id", queue.lead_id);
  } else if (eventType === "Click") {
    await sb.from("leads_master").update({ clicked_email: true }).eq("id", queue.lead_id);
  } else if (eventType === "Bounce" && message.bounce?.bounceType === "Permanent") {
    await sb.from("leads_master").update({ hard_bounce: true, can_email: false }).eq("id", queue.lead_id);
  } else if (eventType === "Complaint") {
    await sb.from("leads_master").update({ unsubscribed_email: true, can_email: false }).eq("id", queue.lead_id);
  }
  return { ok: true, eventType, internalType };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "GET" && url.searchParams.get("health") === "1") {
    const { error } = await sb.from("message_queue").select("id", { count: "exact", head: true }).limit(1);
    return new Response(JSON.stringify({ ok: !error, agent: "ses_webhook", checks: { mode: MODE, db_ok: !error } }), {
      status: error ? 503 : 200,
      headers: { "Content-Type": "application/json" },
    });
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  let msg: Record<string, any>;
  try {
    msg = await req.json();
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  // 1. Firma: sin ella, un POST forjado podría marcar can_email=false a voluntad.
  if (!(await verifySnsSignature(msg).catch((e) => {
    console.error("[ses-webhook] error verificando firma:", e);
    return false;
  }))) {
    console.warn("[ses-webhook] mensaje SNS con firma inválida o ausente — rechazado");
    return new Response("Invalid signature", { status: 403 });
  }

  // 2. Topic esperado (defensa en profundidad).
  if (ALLOWED_TOPIC && String(msg.TopicArn ?? "") !== ALLOWED_TOPIC) {
    console.warn(`[ses-webhook] TopicArn inesperado: ${msg.TopicArn}`);
    return new Response("Unexpected topic", { status: 403 });
  }

  try {
    if (msg.Type === "SubscriptionConfirmation") {
      const subUrl = String(msg.SubscribeURL ?? "");
      if (!isAwsUrl(subUrl)) {
        console.warn("[ses-webhook] SubscribeURL fuera de AWS — ignorada (anti-SSRF)");
        return new Response("Bad SubscribeURL", { status: 403 });
      }
      const res = await fetch(subUrl);
      console.log(`[ses-webhook] suscripción confirmada: HTTP ${res.status}`);
      return new Response("confirmed", { status: 200 });
    }

    if (msg.Type !== "Notification") return new Response("ignored", { status: 200 });

    const out = await handleNotification(msg, MODE);
    console.log("[ses-webhook]", JSON.stringify(out));
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error("[ses-webhook] error:", e);
    return new Response("Internal error", { status: 500 });
  }
});
