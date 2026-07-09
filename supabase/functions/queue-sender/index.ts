// Appril CRM — queue-sender (Fase B de consolidación)
// Drena message_queue → SES / WhatsApp. Reemplazo de la Lambda
// `appril-crm-sender` (appril-sender/src/sender.ts), replicado con fidelidad:
// mismo SELECT, mismo backoff lineal (attempt × 5 min), mismos message_attempts,
// mismos lead_events y los mismos ses_message_id / wa_message_id (el webhook de
// SES y los statuses de Meta correlacionan por ellos).
//
// DIFERENCIA DELIBERADA: el claim es ATÓMICO (RPC queue_claim_batch, FOR UPDATE
// SKIP LOCKED) en vez de marcar el lote entero antes de procesar. Eso mata de
// raíz el bug de "stuck in sending" y hace seguro que convivan dos workers.
//
// Modos (env QUEUE_SENDER_MODE):
//   shadow (default) — NO envía: hace claim, simula, devuelve al estado previo.
//   live             — envía de verdad.
// Auth: x-cron-secret (pg_cron) o service_role. GET ?health=1 sin auth.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SESv2Client, SendEmailCommand } from "https://esm.sh/@aws-sdk/client-sesv2@3";
import { buildRawEmail, renderTemplate } from "./mime.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("QUEUE_SENDER_CRON_SECRET") ?? "";
const MODE = Deno.env.get("QUEUE_SENDER_MODE") ?? "shadow";

const BATCH_SIZE = parseInt(Deno.env.get("BATCH_SIZE") ?? "50");
const MAX_ATTEMPTS = parseInt(Deno.env.get("MAX_ATTEMPTS") ?? "3");
const STALE_MINUTES = parseInt(Deno.env.get("QUEUE_STALE_MINUTES") ?? "10");

const SES_FROM = Deno.env.get("SES_FROM_EMAIL") ?? "";
const SES_REPLY_TO = Deno.env.get("SES_REPLY_TO") ?? "";
const SES_CONFIG_SET = Deno.env.get("SES_CONFIGURATION_SET") ?? "";
const AWS_REGION = Deno.env.get("AWS_REGION") ?? "us-east-1";

const WA_PHONE_ID = Deno.env.get("WA_PHONE_NUMBER_ID") ?? "";
const WA_TOKEN = Deno.env.get("WA_ACCESS_TOKEN") ?? "";
const WA_API_VERSION = Deno.env.get("WA_API_VERSION") ?? "v21.0";

type SendResult = { ok: true; messageId: string } | { ok: false; errorCode: string; errorMessage: string };

const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

// ── WhatsApp (espeja appril-sender/src/whatsapp.ts) ──────────────────────────
function injectPayload(components: unknown, payload: Record<string, unknown>): unknown {
  const json = JSON.stringify(components);
  const replaced = json.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_m, path: string) => {
    const v = path.split(".").reduce<unknown>((acc, k) => (acc as Record<string, unknown>)?.[k], payload);
    return v === undefined || v === null ? "" : String(v).replace(/"/g, '\\"');
  });
  return JSON.parse(replaced);
}

function buildSimpleBody(payload: Record<string, unknown>): unknown[] {
  const values = Object.values(payload ?? {});
  if (values.length === 0) return [];
  return [{ type: "body", parameters: values.map((v) => ({ type: "text", text: String(v ?? "") })) }];
}

async function sendWhatsApp(to: string, template: Record<string, any>, payload: Record<string, unknown>): Promise<SendResult> {
  if (!template.wa_template_name) {
    return { ok: false, errorCode: "INVALID_TEMPLATE", errorMessage: "Template sin wa_template_name" };
  }
  const phone = to.replace(/^\+/, "");
  const components = template.wa_components ? injectPayload(template.wa_components, payload) : buildSimpleBody(payload);
  try {
    const res = await fetch(`https://graph.facebook.com/${WA_API_VERSION}/${WA_PHONE_ID}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${WA_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to: phone,
        type: "template",
        template: { name: template.wa_template_name, language: { code: template.wa_language ?? "es" }, components },
      }),
    });
    const json = await res.json();
    if (!res.ok) {
      return {
        ok: false,
        errorCode: String(json?.error?.code ?? "WA_ERROR"),
        errorMessage: json?.error?.message ?? `HTTP ${res.status}`,
      };
    }
    return { ok: true, messageId: json?.messages?.[0]?.id ?? "" };
  } catch (e) {
    return { ok: false, errorCode: "WA_NETWORK", errorMessage: e instanceof Error ? e.message : String(e) };
  }
}

// ── Email (espeja appril-sender/src/ses.ts, vía SESv2 con Raw MIME) ──────────
let sesClient: SESv2Client | null = null;
function ses(): SESv2Client {
  if (!sesClient) {
    sesClient = new SESv2Client({
      region: AWS_REGION,
      credentials: {
        accessKeyId: Deno.env.get("AWS_SES_ACCESS_KEY_ID")!,
        secretAccessKey: Deno.env.get("AWS_SES_SECRET_ACCESS_KEY")!,
      },
    });
  }
  return sesClient;
}

async function sendEmail(to: string, template: Record<string, any>, payload: Record<string, unknown>): Promise<SendResult> {
  if (!SES_FROM) return { ok: false, errorCode: "CONFIG", errorMessage: "Falta SES_FROM_EMAIL" };
  const subject = template.subject ? renderTemplate(template.subject, payload) : "";
  if (!subject) return { ok: false, errorCode: "INVALID_TEMPLATE", errorMessage: "Template sin subject" };
  const html = template.html_body ? renderTemplate(template.html_body, payload) : "";
  const text = template.text_body ? renderTemplate(template.text_body, payload) : "";
  if (!html && !text) return { ok: false, errorCode: "INVALID_TEMPLATE", errorMessage: "Template sin cuerpo" };

  const raw = buildRawEmail({
    from: SES_FROM,
    to,
    replyTo: SES_REPLY_TO || undefined,
    subject,
    html: html || undefined,
    text: text || undefined,
    unsubscribeUrl: typeof payload?.unsubscribe_url === "string" ? payload.unsubscribe_url : undefined,
  });

  try {
    const out = await ses().send(new SendEmailCommand({
      FromEmailAddress: SES_FROM,
      Destination: { ToAddresses: [to] },
      ...(SES_CONFIG_SET ? { ConfigurationSetName: SES_CONFIG_SET } : {}),
      Content: { Raw: { Data: raw } },
    }));
    return { ok: true, messageId: out.MessageId ?? "" };
  } catch (e) {
    const err = e as { name?: string; message?: string };
    return { ok: false, errorCode: err?.name ?? "SES_ERROR", errorMessage: err?.message ?? String(e) };
  }
}

// ── Drenaje ──────────────────────────────────────────────────────────────────
async function drain(mode: string) {
  const recovered = await sb.rpc("queue_recover_stuck", { p_stale_minutes: STALE_MINUTES, p_max_attempts: MAX_ATTEMPTS });
  if (recovered.error) console.error("[queue-sender] recover error:", recovered.error.message);

  const { data: claimed, error: claimErr } = await sb.rpc("queue_claim_batch", { p_limit: BATCH_SIZE });
  if (claimErr) throw new Error(`claim: ${claimErr.message}`);
  const batch = (claimed ?? []) as Record<string, any>[];
  if (batch.length === 0) return { mode, recovered: recovered.data ?? 0, processed: 0, ok: 0, failed: 0 };

  const keys = [...new Set(batch.map((m) => m.template_key))];
  const { data: tpls } = await sb.from("message_templates")
    .select("template_key, channel, subject, html_body, text_body, wa_template_name, wa_language, wa_components, variables")
    .in("template_key", keys);
  const tplMap = new Map((tpls ?? []).map((t: Record<string, any>) => [t.template_key, t]));

  let ok = 0, failed = 0;
  for (const msg of batch) {
    const template = tplMap.get(msg.template_key);

    if (mode === "shadow") {
      // No envía: devuelve la fila a pending tal cual estaba y registra la simulación.
      await sb.from("message_queue").update({ status: "pending", claimed_at: null }).eq("id", msg.id);
      console.log(`[queue-sender][shadow] ${msg.id} ${msg.channel} → ${msg.to_address} template=${msg.template_key} template_found=${!!template}`);
      ok++;
      continue;
    }

    if (!template) {
      await sb.from("message_queue").update({
        status: "failed",
        claimed_at: null,
        last_error: `TEMPLATE_NOT_FOUND: Template ${msg.template_key} no encontrado o inactivo`,
      }).eq("id", msg.id);
      await sb.from("message_attempts").insert({
        message_id: msg.id,
        attempt_number: (msg.attempts ?? 0) + 1,
        status: "error",
        error_code: "TEMPLATE_NOT_FOUND",
        error_message: `Template ${msg.template_key} no encontrado o inactivo`,
      });
      failed++;
      continue;
    }

    const attemptNumber = (msg.attempts ?? 0) + 1;
    const startedAt = new Date().toISOString();
    const payload = (msg.payload ?? {}) as Record<string, unknown>;
    const result = msg.channel === "email"
      ? await sendEmail(msg.to_address, template, payload)
      : await sendWhatsApp(msg.to_address, template, payload);
    const finishedAt = new Date().toISOString();

    await sb.from("message_attempts").insert({
      message_id: msg.id,
      attempt_number: attemptNumber,
      started_at: startedAt,
      finished_at: finishedAt,
      status: result.ok ? "success" : "error",
      error_code: result.ok ? null : result.errorCode,
      error_message: result.ok ? null : result.errorMessage,
      response_payload: result.ok ? { messageId: result.messageId } : null,
    });

    if (result.ok) {
      await sb.from("message_queue").update({
        status: "sent",
        sent_at: new Date().toISOString(),
        attempts: attemptNumber,
        claimed_at: null,
        ses_message_id: msg.channel === "email" ? result.messageId : null,
        wa_message_id: msg.channel !== "email" ? result.messageId : null,
      }).eq("id", msg.id);

      await sb.from("lead_events").insert({
        workspace_id: msg.workspace_id,
        lead_id: msg.lead_id,
        event_type: "message_sent",
        event_channel: msg.channel,
        event_value: msg.template_key,
        metadata: {
          message_id: msg.id,
          external_id: result.messageId,
          campaign_id: msg.campaign_id ?? null,
          template_key: msg.template_key,
        },
      });
      if (msg.lead_id) {
        await sb.from("leads_master").update({
          last_contacted_at: new Date().toISOString(),
          last_channel_touched: msg.channel,
        }).eq("id", msg.lead_id);
      }
      ok++;
    } else {
      const exhausted = attemptNumber >= MAX_ATTEMPTS;
      await sb.from("message_queue").update({
        status: exhausted ? "failed" : "pending",
        attempts: attemptNumber,
        claimed_at: null,
        last_error: `${result.errorCode}: ${result.errorMessage}`,
        // Backoff lineal idéntico al Lambda: attemptNumber × 5 minutos.
        scheduled_at: exhausted ? msg.scheduled_at : new Date(Date.now() + attemptNumber * 5 * 60_000).toISOString(),
      }).eq("id", msg.id);
      failed++;
    }
  }

  return { mode, recovered: recovered.data ?? 0, processed: batch.length, ok, failed };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "GET" && url.searchParams.get("health") === "1") {
    const { error } = await sb.from("message_queue").select("id", { count: "exact", head: true }).limit(1);
    const checks = {
      mode: MODE,
      env_ses_from: !!SES_FROM,
      env_ses_keys: !!Deno.env.get("AWS_SES_ACCESS_KEY_ID") && !!Deno.env.get("AWS_SES_SECRET_ACCESS_KEY"),
      env_wa_token: !!WA_TOKEN,
      env_wa_phone_id: !!WA_PHONE_ID,
      db_ok: !error,
    };
    const okAll = checks.env_ses_from && checks.env_ses_keys && checks.env_wa_token && checks.env_wa_phone_id && checks.db_ok;
    return new Response(JSON.stringify({ ok: okAll, agent: "queue_sender", checks }), {
      status: okAll ? 200 : 503,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const auth = req.headers.get("authorization") ?? "";
  const cronSecret = req.headers.get("x-cron-secret") ?? "";
  const authorized = (CRON_SECRET && cronSecret === CRON_SECRET) || auth === `Bearer ${SERVICE_KEY}`;
  if (!authorized) return new Response("Unauthorized", { status: 401 });

  // Permite forzar modo por request (para pruebas de sombra): {"mode":"shadow"}.
  let bodyMode: string | undefined;
  try {
    const body = await req.json();
    bodyMode = typeof body?.mode === "string" ? body.mode : undefined;
  } catch { /* sin body */ }
  const mode = bodyMode === "live" || bodyMode === "shadow" ? bodyMode : MODE;

  try {
    const out = await drain(mode);
    console.log("[queue-sender]", JSON.stringify(out));
    return new Response(JSON.stringify(out), { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("[queue-sender] error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }), { status: 500 });
  }
});
