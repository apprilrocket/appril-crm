// Appril Discovery — send-discovery-email
// Envía el email de "diagnóstico de agenda" generado por el wizard de Discovery.
// Diseño server-side compatible Gmail/Outlook: tablas + estilos inline, sin flex/grid/JS.
// Cifras en la moneda seleccionada por el lead (frontend_calculations.currency).
// Transporte: SES (mismo patrón EXACTO que supabase/functions/inbox-send/index.ts).
// Disparo previsto: trigger pg_net AFTER INSERT on discovery_leads -> POST { discovery_lead_id }.
//   (ver supabase/migrations/20260629_1510_discovery_email_dispatch.sql)
// Idempotente: si ya existe lead_event 'discovery_email_sent' para el id, no reenvía (salvo force=true).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SESv2Client, SendEmailCommand } from "https://esm.sh/@aws-sdk/client-sesv2@3";

// ── Config / entorno ───────────────────────────────────────────────────────────
// Remitente unificado: todo Appril sale de hola@appril.co (envía y recibe).
const FROM_EMAIL = Deno.env.get("DISCOVERY_FROM_EMAIL") ?? "Appril <hola@appril.co>";
// CTA destino (configurable por env); se le agregan los UTM del lead.
// Link de registro OFICIAL (no app.appril.co/auth/sign-up, que es el heredado).
const CTA_BASE_URL = Deno.env.get("DISCOVERY_CTA_URL") ?? "https://www.appril.co/empezar";

// CTA a WhatsApp → despierta al whatsapp-agent con contexto de Discovery.
const AGENT_WA_NUMBER = (Deno.env.get("DISCOVERY_AGENT_WA_NUMBER") ?? "573112211772").replace(/\D/g, "");
const WA_CTA_MESSAGE = "Hola, recibí mi diagnóstico de Appril y quiero activar mi mes gratis.";
const WA_CTA_LABEL = "Activar mi mes gratis por WhatsApp";

const SUBJECT = "Su diagnóstico está listo";
// Preheader dinámico: si hay costo oculto se arma con la cifra (en el handler);
// si no, este fallback.
const PREHEADER_FALLBACK =
  "Vea dónde se le están escapando dinero, tiempo y oportunidades.";
// CTA secundario (crear cuenta). El CTA PRINCIPAL post-Discovery es WhatsApp.
const CTA_LABEL_DEFAULT = "Crear cuenta sin tarjeta";

// Secretos aceptados para autorizar la invocación. El disparador pg_net manda el
// secret tanto en `Authorization: Bearer <secret>` como en `x-discovery-dispatch-secret`
// (ver migración). Aceptamos ambos nombres de env + el service_role key para que el
// endpoint NO quede abierto por defecto (cierra spam/enumeración de leads).
const ALLOWED_SECRETS = [
  Deno.env.get("DISCOVERY_EMAIL_SECRET") ?? "",
  Deno.env.get("DISCOVERY_DISPATCH_SECRET") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
].filter((s) => s.length > 0);

// ── CORS ────────────────────────────────────────────────────────────────────────
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-discovery-secret, x-discovery-dispatch-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// Comparación de tiempo (cuasi) constante para no filtrar el secret por timing.
function secretMatches(provided: string): boolean {
  if (!provided) return false;
  let ok = false;
  for (const s of ALLOWED_SECRETS) {
    if (provided.length === s.length) {
      let diff = 0;
      for (let i = 0; i < s.length; i++) diff |= provided.charCodeAt(i) ^ s.charCodeAt(i);
      if (diff === 0) ok = true;
    }
  }
  return ok;
}

// ── Mapa de títulos de oportunidad principal (risk_dominant -> título ES) ─────────
const RISK_TITLES: Record<string, string> = {
  no_show: "Confirmaciones y ausencias que se te están escapando",
  no_shows: "Confirmaciones y ausencias que se te están escapando",
  cancellation: "Cancelaciones de último momento sin reemplazo",
  cancellations: "Cancelaciones de último momento sin reemplazo",
  lost_appointments: "Citas que se pierden antes de agendarse",
  lost: "Citas que se pierden antes de agendarse",
  admin_time: "Tiempo administrativo que podrías recuperar",
  admin: "Tiempo administrativo que podrías recuperar",
  time: "Tiempo administrativo que podrías recuperar",
  empty_slots: "Espacios vacíos en tu agenda sin llenar",
  idle_capacity: "Espacios vacíos en tu agenda sin llenar",
  capacity: "Espacios vacíos en tu agenda sin llenar",
  whatsapp_overload: "Saturación de WhatsApp en la coordinación de citas",
  whatsapp: "Saturación de WhatsApp en la coordinación de citas",
  manual_scheduling: "Agendamiento manual propenso a errores",
  no_system: "Falta de un sistema centralizado de agenda",
  revenue_leak: "Ingresos que se te pueden estar filtrando",
};

const RISK_TITLE_FALLBACK = "La principal oportunidad de tu agenda";

// ── Helpers de formato ───────────────────────────────────────────────────────────
function firstName(full?: string | null): string {
  const n = (full ?? "").trim();
  // Fallback de saludo alineado con lead_var_value(_, 'nombre') del CRM.
  if (!n) return "Doctor(a)";
  return n.split(/\s+/)[0];
}

function escapeHtml(s: unknown): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function toNumber(v: unknown): number {
  const n = typeof v === "string" ? Number(v.replace(/[^\d.-]/g, "")) : Number(v);
  return Number.isFinite(n) ? n : 0;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Códigos que comparten el glifo "$" — hay que desambiguar con el código ISO.
const AMBIGUOUS_DOLLAR = new Set([
  "USD", "MXN", "ARS", "COP", "CLP", "UYU", "DOP", "CRC", "CUP", "AUD", "CAD", "NZD", "HKD", "SGD",
]);

// Formatea un monto en moneda local. usdAmount * fx -> local.
// OJO: `fx` se interpreta como factor USD->local por consigna explícita (USD*fx_rate_to_usd).
function fmtMoney(
  usdAmount: number,
  fx: number,
  symbol: string,
  code: string,
): string {
  const local = usdAmount * (fx && fx > 0 ? fx : 1);
  const rounded = Math.round(local);
  // Agrupación de miles con punto (es-CO / es-419). Sin decimales para cifras grandes.
  const grouped = rounded.toLocaleString("es-CO");
  const sym = symbol && symbol.trim() ? symbol.trim() : (code || "USD");
  const needsCode = sym === "$" && AMBIGUOUS_DOLLAR.has((code || "").toUpperCase());
  const codeSuffix = needsCode ? ` ${(code || "").toUpperCase()}` : "";
  return `${sym} ${grouped}${codeSuffix}`;
}

function fmtHours(h: number): string {
  const rounded = Math.round(h);
  return `${rounded.toLocaleString("es-CO")} h`;
}

function buildCtaUrl(
  base: string,
  utm: Record<string, string | null | undefined>,
  dlToken?: string | null,
): string {
  let url: URL;
  try {
    url = new URL(base);
  } catch {
    return base;
  }
  const keys = ["utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term"];
  for (const k of keys) {
    const v = utm[k];
    if (v) url.searchParams.set(k, String(v));
  }
  if (!url.searchParams.has("utm_source")) url.searchParams.set("utm_source", "discovery_email");
  if (!url.searchParams.has("utm_medium")) url.searchParams.set("utm_medium", "email");
  // Atribución lead→cuenta: el token opaco `dl` (leads_master.dl_token) viaja hasta el
  // signup para poder cerrar el loop account_created→CRM sin exponer lead_id crudo.
  if (dlToken) url.searchParams.set("dl", dlToken);
  return url.toString();
}

// ── Construcción del HTML (tablas + inline; Gmail/Outlook safe) ──────────────────
// El modelo guarda valores CRUDOS (sin escapar). renderHtml escapa una sola vez;
// renderText usa los valores crudos. NUNCA pre-escapar al construir el modelo.
type EmailModel = {
  name: string;
  preheader: string;
  hiddenCostKnown: boolean;
  riskTitle: string;
  evidence: string;
  lostRevenue: string;
  adminHours: string;
  hiddenCost: string;
  ctaUrl: string;
  ctaLabel: string;
  waUrl: string;
  waLabel: string;
};

function renderHtml(m: EmailModel): string {
  const pre = escapeHtml(m.preheader);
  return `<!DOCTYPE html>
<html lang="es" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>${escapeHtml(SUBJECT)}</title>
<!--[if mso]>
<noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript>
<![endif]-->
</head>
<body style="margin:0;padding:0;background-color:#f4f5f7;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<!-- preheader oculto -->
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:#f4f5f7;opacity:0;">${pre}&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;">
  <tr>
    <td align="center" style="padding:24px 12px;">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;">
        <!-- Header -->
        <tr>
          <td style="background-color:#0f172a;padding:28px 32px;">
            <span style="font-size:20px;font-weight:700;color:#ffffff;letter-spacing:0.3px;">Appril</span>
          </td>
        </tr>
        <!-- Saludo + título -->
        <tr>
          <td style="padding:32px 32px 8px;">
            <p style="margin:0 0 6px;font-size:15px;color:#475569;line-height:1.6;">Hola, ${escapeHtml(m.name)} 👋</p>
            <h1 style="margin:0 0 12px;font-size:23px;line-height:1.3;color:#0f172a;font-weight:700;">Su diagnóstico está listo</h1>
            <p style="margin:0;font-size:15px;color:#475569;line-height:1.6;">Gracias por completar el diagnóstico. Esto es lo que encontramos.</p>
          </td>
        </tr>
        ${m.hiddenCostKnown ? `<!-- Oportunidad estimada (solo si hay costo oculto) -->
        <tr>
          <td style="padding:24px 32px 0;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#0f172a;border-radius:10px;">
              <tr><td align="center" style="padding:26px 24px;">
                <p style="margin:0 0 6px;font-size:13px;color:#cbd5e1;line-height:1.4;">Oportunidad estimada al año</p>
                <p style="margin:0;font-size:32px;font-weight:800;color:#ffffff;line-height:1.1;">${escapeHtml(m.hiddenCost)}</p>
              </td></tr>
            </table>
          </td>
        </tr>` : ""}
        <!-- Bloque 1: El punto más importante -->
        <tr>
          <td style="padding:24px 32px 8px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f0f9ff;border-left:4px solid #0ea5e9;border-radius:8px;">
              <tr>
                <td style="padding:18px 20px;">
                  <p style="margin:0 0 6px;font-size:12px;letter-spacing:0.6px;text-transform:uppercase;color:#0369a1;font-weight:700;">El punto más importante</p>
                  <p style="margin:0 0 8px;font-size:18px;line-height:1.4;color:#0f172a;font-weight:700;">${escapeHtml(m.riskTitle)}</p>
                  ${m.evidence ? `<p style="margin:0;font-size:14px;color:#334155;line-height:1.6;">${escapeHtml(m.evidence)}</p>` : ""}
                </td>
              </tr>
            </table>
          </td>
        </tr>
        <!-- Bloque 2: Qué significa -->
        <tr>
          <td style="padding:20px 32px 8px;">
            <p style="margin:0 0 8px;font-size:16px;font-weight:700;color:#0f172a;">Qué significa</p>
            <p style="margin:0;font-size:14px;color:#334155;line-height:1.6;">Su consultorio puede estar perdiendo dinero antes de que el paciente llegue: en confirmaciones pendientes, cancelaciones tarde, tiempo de WhatsApp o espacios que no se recuperan.</p>
          </td>
        </tr>
        <!-- Bloque 3: Impacto estimado: 3 cifras -->
        <tr>
          <td style="padding:24px 32px 8px;">
            <p style="margin:0 0 14px;font-size:12px;letter-spacing:0.6px;text-transform:uppercase;color:#64748b;font-weight:700;">Impacto estimado</p>
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
              <tr>
                <td width="33%" valign="top" style="padding:0 6px 0 0;">
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fef2f2;border-radius:8px;">
                    <tr><td align="center" style="padding:16px 8px;">
                      <p style="margin:0 0 4px;font-size:18px;font-weight:700;color:#b91c1c;line-height:1.2;">${escapeHtml(m.lostRevenue)}</p>
                      <p style="margin:0;font-size:12px;color:#7f1d1d;line-height:1.4;">Pérdida anual estimada</p>
                    </td></tr>
                  </table>
                </td>
                <td width="34%" valign="top" style="padding:0 3px;">
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fffbeb;border-radius:8px;">
                    <tr><td align="center" style="padding:16px 8px;">
                      <p style="margin:0 0 4px;font-size:18px;font-weight:700;color:#b45309;line-height:1.2;">${escapeHtml(m.adminHours)}</p>
                      <p style="margin:0;font-size:12px;color:#78350f;line-height:1.4;">Horas administrativas estimadas</p>
                    </td></tr>
                  </table>
                </td>
                <td width="33%" valign="top" style="padding:0 0 0 6px;">
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f1f5f9;border-radius:8px;">
                    <tr><td align="center" style="padding:16px 8px;">
                      <p style="margin:0 0 4px;font-size:18px;font-weight:700;color:#334155;line-height:1.2;">${escapeHtml(m.hiddenCost)}</p>
                      <p style="margin:0;font-size:12px;color:#475569;line-height:1.4;">Costo oculto total</p>
                    </td></tr>
                  </table>
                </td>
              </tr>
            </table>
          </td>
        </tr>
        <!-- Disclaimer -->
        <tr>
          <td style="padding:12px 32px 8px;">
            <p style="margin:0;font-size:12px;color:#94a3b8;line-height:1.5;font-style:italic;">Estas cifras son estimaciones basadas en sus respuestas. No son una promesa de ahorro.</p>
          </td>
        </tr>
        <!-- Bloque 4: Cómo puede ayudar Appril -->
        <tr>
          <td style="padding:20px 32px 8px;">
            <p style="margin:0 0 12px;font-size:16px;font-weight:700;color:#0f172a;">Cómo puede ayudar Appril</p>
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
              <tr><td style="padding:0 0 10px;font-size:14px;color:#334155;line-height:1.6;">✅ Sus pacientes pueden confirmar, cancelar o reagendar con más claridad.</td></tr>
              <tr><td style="padding:0 0 10px;font-size:14px;color:#334155;line-height:1.6;">✅ Su consultorio deja de perseguir paciente por paciente.</td></tr>
              <tr><td style="padding:0 0 4px;font-size:14px;color:#334155;line-height:1.6;">✅ Usted puede ver quién confirmó, quién sigue pendiente y qué espacios requieren acción.</td></tr>
            </table>
          </td>
        </tr>
        <!-- Bloque 5: Active su mes gratis (CTA principal = WhatsApp, secundario = registro) -->
        <tr>
          <td style="padding:20px 32px 8px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#0f172a;border-radius:10px;">
              <tr>
                <td align="center" style="padding:28px 24px;">
                  <p style="margin:0 0 6px;font-size:18px;font-weight:700;color:#ffffff;line-height:1.4;">Active su mes gratis</p>
                  <p style="margin:0 0 20px;font-size:14px;color:#cbd5e1;line-height:1.6;">Por haber hecho el diagnóstico, puede probar Appril sin tarjeta.</p>
                  <!--[if mso]>
                  <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="${escapeHtml(m.waUrl)}" style="height:48px;v-text-anchor:middle;width:320px;" arcsize="14%" stroke="f" fillcolor="#25D366">
                  <w:anchorlock/>
                  <center style="color:#0b3d2e;font-family:Arial,sans-serif;font-size:15px;font-weight:bold;">${escapeHtml(m.waLabel)}</center>
                  </v:roundrect>
                  <![endif]-->
                  <!--[if !mso]><!-- -->
                  <a href="${escapeHtml(m.waUrl)}" target="_blank" style="display:inline-block;background-color:#25D366;color:#0b3d2e;font-size:15px;font-weight:700;text-decoration:none;padding:14px 32px;border-radius:8px;">${escapeHtml(m.waLabel)}</a>
                  <!--<![endif]-->
                  <p style="margin:16px 0 0;font-size:13px;line-height:1.5;"><a href="${escapeHtml(m.ctaUrl)}" target="_blank" style="color:#cbd5e1;text-decoration:underline;">${escapeHtml(m.ctaLabel)}</a></p>
                </td>
              </tr>
            </table>
          </td>
        </tr>
        <!-- Footer -->
        <tr>
          <td style="padding:24px 32px 32px;">
            <p style="margin:0 0 4px;font-size:12px;color:#94a3b8;line-height:1.5;">Recibió este correo porque completó el diagnóstico de Appril.</p>
            <p style="margin:0;font-size:12px;color:#94a3b8;line-height:1.5;">Appril · <a href="https://appril.co" style="color:#64748b;text-decoration:underline;">appril.co</a></p>
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>`;
}

function renderText(m: EmailModel): string {
  return [
    `Hola, ${m.name}`,
    ``,
    `Su diagnóstico está listo.`,
    ``,
    m.hiddenCostKnown ? `Encontramos una oportunidad estimada de ${m.hiddenCost} al año.` : null,
    m.hiddenCostKnown ? `` : null,
    `El punto más importante:`,
    m.riskTitle,
    ``,
    m.evidence ? m.evidence : ``,
    ``,
    `Qué significa:`,
    `Su consultorio puede estar perdiendo dinero antes de que el paciente llegue: en confirmaciones pendientes, cancelaciones tarde, tiempo de WhatsApp o espacios que no se recuperan.`,
    ``,
    `Impacto estimado al año:`,
    `- Pérdida anual estimada: ${m.lostRevenue}`,
    `- Horas administrativas estimadas: ${m.adminHours}`,
    `- Costo oculto total: ${m.hiddenCost}`,
    ``,
    `Estas cifras son estimaciones basadas en sus respuestas. No son una promesa de ahorro.`,
    ``,
    `Cómo puede ayudar Appril:`,
    `- Sus pacientes pueden confirmar, cancelar o reagendar con más claridad.`,
    `- Su consultorio deja de perseguir paciente por paciente.`,
    `- Usted puede ver quién confirmó, quién sigue pendiente y qué espacios requieren acción.`,
    ``,
    `Por haber hecho el diagnóstico, puede activar un mes gratis de Appril.`,
    ``,
    `Activar mi mes gratis por WhatsApp:`,
    m.waUrl,
    ``,
    `Crear cuenta sin tarjeta:`,
    m.ctaUrl,
    ``,
    `Appril`,
  ].filter((l) => l !== null).join("\n");
}

// ── Handler ──────────────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { ok: false, error: "method not allowed" });

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    return json(400, { ok: false, error: "body JSON inválido" });
  }

  // Autorización: el disparador pg_net manda el secret en Authorization: Bearer y/o
  // en x-discovery-dispatch-secret. Aceptamos también x-discovery-secret y body.secret.
  // Si hay secretos configurados (siempre, porque SERVICE_ROLE_KEY existe), se exige match.
  if (ALLOWED_SECRETS.length > 0) {
    const authHeader = req.headers.get("authorization") ?? "";
    const bearer = authHeader.toLowerCase().startsWith("bearer ")
      ? authHeader.slice(7).trim()
      : "";
    const provided =
      bearer ||
      req.headers.get("x-discovery-dispatch-secret") ||
      req.headers.get("x-discovery-secret") ||
      (typeof body?.secret === "string" ? body.secret : "") ||
      "";
    if (!secretMatches(provided)) {
      return json(401, { ok: false, error: "no autorizado" });
    }
  }

  const discoveryLeadId = body?.discovery_lead_id ?? body?.id ?? body?.record?.id;
  const force = body?.force === true || body?.force === "true";
  if (!discoveryLeadId) {
    return json(400, { ok: false, error: "discovery_lead_id es requerido" });
  }

  try {
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Solo columnas que EXISTEN en public.discovery_leads (verificado contra schema.sql).
    // El CTA label / recommended_action viven en frontend_calculations/findings (jsonb),
    // no como columnas dedicadas todavía.
    const { data: dlRaw, error: dlErr } = await sb
      .from("discovery_leads")
      .select(
        "id, workspace_id, lead_id, full_name, email, city, " +
          "marketing_segment, score, findings, frontend_calculations, " +
          "annual_lost_revenue, hidden_cost_total, " +
          "utm_source, utm_medium, utm_campaign, utm_content, utm_term",
      )
      .eq("id", discoveryLeadId)
      .single();

    // supabase-js tipa el resultado de .single() como union con GenericStringError;
    // ya validamos error/null abajo, así que trabajamos con un shape laxo.
    const dl = dlRaw as Record<string, any> | null;

    if (dlErr || !dl) {
      // No logueamos PII; el id no es sensible.
      console.error("send-discovery-email lookup miss:", dlErr?.code ?? "not_found");
      return json(404, { ok: false, error: "discovery_lead no encontrado" });
    }

    const email = typeof dl.email === "string" ? dl.email.trim() : "";
    if (!email) {
      return json(200, { ok: false, skipped: "no_email" });
    }
    if (!EMAIL_RE.test(email)) {
      return json(200, { ok: false, skipped: "invalid_email" });
    }

    // Idempotencia: ¿ya se envió?
    if (!force) {
      const { data: prior } = await sb
        .from("lead_events")
        .select("id")
        .eq("event_type", "discovery_email_sent")
        .contains("metadata", { discovery_lead_id: String(discoveryLeadId) })
        .limit(1);
      if (prior && prior.length > 0) {
        return json(200, { ok: true, skipped: "already_sent" });
      }
    }

    // ── Extracción de datos (frontend_calculations preferente, findings/columns fallback) ──
    const findings = (dl.findings ?? {}) as Record<string, any>;
    const fc = (dl.frontend_calculations ?? {}) as Record<string, any>;
    const currency = (fc.currency ?? {}) as Record<string, any>;

    const selectedCode = String(currency.selected_currency ?? "USD").toUpperCase();
    const symbol = String(currency.selected_currency_symbol ?? currency.symbol ?? "$");
    const fx = toNumber(currency.fx_rate_to_usd ?? currency.fx_rate) || 1;

    // Las cifras se guardan en USD; se convierten a la moneda local con fx (USD*fx).
    const usdLostRevenue =
      toNumber(fc.annual_lost_revenue) ||
      toNumber(findings.annual_lost_revenue) ||
      toNumber(dl.annual_lost_revenue);
    const annualAdminHours =
      toNumber(fc.annual_admin_hours) || toNumber(findings.annual_admin_hours);
    const usdHiddenCost =
      toNumber(fc.hidden_cost_total) ||
      toNumber(findings.hidden_cost_total) ||
      toNumber(dl.hidden_cost_total);

    // Sanity-check de dirección de conversión (no aborta; solo observabilidad).
    if (fx > 0 && fx < 1 && usdLostRevenue > 0 && usdLostRevenue * fx < 1) {
      console.warn(
        "send-discovery-email: fx_rate_to_usd<1 produce cifra local <1 — revisar dirección de conversión",
      );
    }

    // Oportunidad principal
    const riskKey = String(findings.risk_dominant ?? "").toLowerCase();
    const riskTitle = RISK_TITLES[riskKey] ?? RISK_TITLE_FALLBACK;

    // Evidencia: risk_evidence puede ser array de strings/objetos o string.
    let evidence = "";
    const ev = findings.risk_evidence;
    if (Array.isArray(ev)) {
      evidence = ev
        .map((e: any) => (typeof e === "string" ? e : e?.label ?? e?.text ?? e?.description ?? ""))
        .filter((s: string) => s && s.trim())
        .join(" · ");
    } else if (typeof ev === "string") {
      evidence = ev;
    }

    // CTA label desde frontend_calculations/findings (no hay columna dedicada aún).
    const ctaLabel =
      String(
        fc.primary_cta_label ??
          findings.primary_cta_label ??
          fc.cta_label ??
          CTA_LABEL_DEFAULT,
      ).trim() || CTA_LABEL_DEFAULT;

    // Token opaco de atribución del lead (puede no existir si el discovery no resolvió lead).
    let dlToken: string | null = null;
    if (dl.lead_id) {
      const { data: lm } = await sb
        .from("leads_master")
        .select("dl_token")
        .eq("id", dl.lead_id)
        .maybeSingle();
      dlToken = (lm as any)?.dl_token ?? null;
    }

    const ctaUrl = buildCtaUrl(CTA_BASE_URL, {
      utm_source: dl.utm_source,
      utm_medium: dl.utm_medium,
      utm_campaign: dl.utm_campaign,
      utm_content: dl.utm_content,
      utm_term: dl.utm_term,
    }, dlToken);

    // Costo oculto: condiciona el preheader y el bloque destacado (no inventar $0).
    const hiddenCostStr = fmtMoney(usdHiddenCost, fx, symbol, selectedCode);
    const hiddenCostKnown = usdHiddenCost > 0;
    const preheader = hiddenCostKnown
      ? `Tiene una oportunidad estimada de ${hiddenCostStr} al año.`
      : PREHEADER_FALLBACK;

    // Modelo con valores CRUDOS (renderHtml escapa; renderText usa crudo).
    const model: EmailModel = {
      name: firstName(dl.full_name),
      preheader,
      hiddenCostKnown,
      riskTitle,
      evidence,
      lostRevenue: fmtMoney(usdLostRevenue, fx, symbol, selectedCode),
      adminHours: fmtHours(annualAdminHours),
      hiddenCost: hiddenCostStr,
      ctaUrl,
      ctaLabel,
      waUrl: `https://wa.me/${AGENT_WA_NUMBER}?text=${encodeURIComponent(WA_CTA_MESSAGE)}`,
      waLabel: WA_CTA_LABEL,
    };

    const html = renderHtml(model);
    const text = renderText(model);

    // ── SES (patrón exacto de inbox-send) ──────────────────────────────────────────
    const ses = new SESv2Client({
      region: Deno.env.get("AWS_REGION") || Deno.env.get("AWS_SES_REGION") || "us-east-1",
      credentials: {
        accessKeyId:
          Deno.env.get("AWS_ACCESS_KEY_ID") ?? Deno.env.get("AWS_SES_ACCESS_KEY_ID")!,
        secretAccessKey:
          Deno.env.get("AWS_SECRET_ACCESS_KEY") ?? Deno.env.get("AWS_SES_SECRET_ACCESS_KEY")!,
      },
    });

    const out = await ses.send(
      new SendEmailCommand({
        FromEmailAddress: FROM_EMAIL,
        Destination: { ToAddresses: [email] },
        Content: {
          Simple: {
            Subject: { Data: SUBJECT, Charset: "UTF-8" },
            Body: {
              Html: { Data: html, Charset: "UTF-8" },
              Text: { Data: text, Charset: "UTF-8" },
            },
          },
        },
      }),
    );

    const sesMessageId = (out as any)?.MessageId ?? null;

    // ── Registro en lead_events (idempotencia de entrega para Fase 1) ──────────────
    await sb.from("lead_events").insert({
      workspace_id: dl.workspace_id,
      lead_id: dl.lead_id ?? null,
      event_type: "discovery_email_sent",
      event_channel: "email",
      event_value: email,
      metadata: {
        discovery_lead_id: String(discoveryLeadId),
        ses_message_id: sesMessageId,
        subject: SUBJECT,
        currency: selectedCode,
        marketing_segment: dl.marketing_segment ?? null,
        forced: force,
      },
    });

    return json(200, { ok: true, ses_message_id: sesMessageId });
  } catch (err) {
    // No filtrar detalle de SES/infra al cliente; log server-side sin PII.
    console.error("send-discovery-email error:", err instanceof Error ? err.message : String(err));
    return json(500, { ok: false, error: "internal_error" });
  }
});
