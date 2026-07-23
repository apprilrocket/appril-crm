import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { GuardrailError } from "./guardrails.js";

import { listSegments } from "./lib/segments.js";
import { listLeadLists, createList, importContacts } from "./lib/leadsLists.js";
import { listTemplates, getTemplate, listWaTemplates, createEmailTemplate, updateEmailTemplate } from "./lib/templates.js";
import { previewAudience, createCampaign, scheduleCampaign, listCampaigns, getCampaign } from "./lib/campaigns.js";
import { listAutomations, getAutomation, createAutomation, updateAutomation } from "./lib/automations.js";
import { queueStatus, campaignStats } from "./lib/monitoring.js";
import { sendTest } from "./lib/test.js";
import { searchLeads, getLead, leadTimeline } from "./lib/leads.js";
import { inboxThreads, getConversation } from "./lib/inbox.js";
import { getReport } from "./lib/reports.js";
import { agentHealth } from "./lib/health.js";
import { updateLeadStage, updateLead, addLeadNote, createLeadTask, completeLeadTask, setAgentPaused } from "./lib/leadsWrite.js";

type Result = { content: { type: "text"; text: string }[]; isError?: boolean };

function okResult(data: unknown): Result {
  return { content: [{ type: "text", text: typeof data === "string" ? data : JSON.stringify(data, null, 2) }] };
}
function failResult(msg: string): Result {
  return { content: [{ type: "text", text: `ERROR: ${msg}` }], isError: true };
}

/** Envuelve un handler: serializa el resultado y captura errores/guardas como texto. */
function wrap<A>(fn: (a: A) => Promise<unknown>) {
  return async (a: A): Promise<Result> => {
    try {
      return okResult(await fn(a));
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      return e instanceof GuardrailError ? failResult(`[guardarraíl] ${msg}`) : failResult(msg);
    }
  };
}

export function buildServer(): McpServer {
  const server = new McpServer({ name: "appril-mcp-campaigns", version: "0.1.0" });

  // ── Contactos y listas ────────────────────────────────────────────────────
  server.registerTool("list_segments",
    { description: "Lista los segmentos de marketing con audiencia total y elegibles por canal (snapshot en vivo).", inputSchema: {} },
    wrap(() => listSegments()));

  server.registerTool("list_lead_lists",
    { description: "Lista las listas de contactos con su número de miembros.", inputSchema: {} },
    wrap(() => listLeadLists()));

  server.registerTool("create_list",
    {
      description: "Crea una lista de contactos vacía.",
      inputSchema: { name: z.string(), description: z.string().optional(), source_type: z.enum(["manual", "csv_import", "webhook"]).optional() },
    },
    wrap(createList));

  server.registerTool("import_contacts",
    {
      description: "Importa contactos a una lista (la crea si no existe). Normaliza email/teléfono E.164, deduplica en-archivo y contra la BD. Marca contactos nuevos como COLD por defecto.",
      inputSchema: {
        list_name: z.string(),
        segment: z.enum(["SUPER_HOT", "HOT", "WARM", "COLD"]).optional(),
        contacts: z.array(z.object({
          full_name: z.string().optional(),
          first_name: z.string().optional().describe("Nombre de saludo opcional. Si se omite, se deriva del full_name."),
          email: z.string().optional(),
          phone: z.string().optional(),
          city: z.string().optional(),
          specialization: z.string().optional(),
          country: z.string().optional(),
          whatsapp_opted_in: z.boolean().optional().describe("Consentimiento WhatsApp del lead. true/false. Default false. NO lo pongas true sin base real de consentimiento."),
        })).min(1),
      },
    },
    wrap(importContacts));

  // ── Copys / templates ─────────────────────────────────────────────────────
  server.registerTool("list_templates",
    { description: "Lista templates (copys). Filtra por canal/estado.", inputSchema: { channel: z.enum(["email", "whatsapp"]).optional(), status: z.enum(["draft", "active", "archived"]).optional() } },
    wrap(listTemplates));

  server.registerTool("get_template",
    { description: "Devuelve un template completo por su template_key.", inputSchema: { template_key: z.string() } },
    wrap((a: { template_key: string }) => getTemplate(a.template_key)));

  server.registerTool("list_wa_templates",
    { description: "Lista los templates de WhatsApp APROBADOS por Meta (listos para usar en campañas/automations). Sólo lectura: la IA no puede crear copys de WhatsApp.", inputSchema: {} },
    wrap(() => listWaTemplates()));

  server.registerTool("create_email_template",
    {
      description: "Crea un copy de EMAIL (subject + html_body + text_body opcional). Extrae variables {{...}} automáticamente. Por defecto queda en draft; activate=true lo activa si tiene subject y html_body.",
      inputSchema: {
        name: z.string(),
        subject: z.string(),
        html_body: z.string(),
        text_body: z.string().optional(),
        description: z.string().optional(),
        activate: z.boolean().optional(),
      },
    },
    wrap(createEmailTemplate));

  server.registerTool("update_email_template",
    {
      description: "Edita un copy de email existente. Re-extrae variables. Para activar requiere subject y html_body.",
      inputSchema: {
        template_key: z.string(),
        name: z.string().optional(),
        subject: z.string().optional(),
        html_body: z.string().optional(),
        text_body: z.string().optional(),
        status: z.enum(["draft", "active", "archived"]).optional(),
      },
    },
    wrap(updateEmailTemplate));

  // ── Campañas ──────────────────────────────────────────────────────────────
  server.registerTool("preview_audience",
    {
      description: "Calcula audiencia total vs destinatarios ELEGIBLES (tras guardas de canal) para una combinación de segmentos/listas. Úsalo SIEMPRE antes de crear una campaña.",
      inputSchema: {
        channel: z.enum(["email", "whatsapp"]),
        segments: z.array(z.string()).optional(),
        list_ids: z.array(z.string()).optional(),
        allow_no_optin: z.boolean().optional(),
      },
    },
    wrap(previewAudience));

  server.registerTool("create_campaign",
    {
      description: "Crea una campaña en BORRADOR (nunca la lanza). Valida que el template exista, esté activo y sea del canal. Devuelve el preview de audiencia.",
      inputSchema: {
        name: z.string(),
        channel: z.enum(["email", "whatsapp"]),
        template_key: z.string(),
        segments: z.array(z.string()).optional(),
        list_ids: z.array(z.string()).optional(),
        allow_no_optin: z.boolean().optional(),
        description: z.string().optional(),
      },
    },
    wrap(createCampaign));

  server.registerTool("schedule_campaign",
    {
      description: "Programa una campaña borrador (fija fecha de envío y la deja lista para revisión). NO la aprueba ni la envía: un humano debe aprobarla para que el scheduler la lance.",
      inputSchema: { campaign_id: z.string(), scheduled_at: z.string().describe("ISO 8601, p.ej. 2026-06-30T14:00:00Z") },
    },
    wrap(scheduleCampaign));

  server.registerTool("list_campaigns",
    { description: "Lista campañas (filtra por estado).", inputSchema: { status: z.enum(["draft", "scheduled", "running", "paused", "done", "cancelled"]).optional() } },
    wrap(listCampaigns));

  server.registerTool("get_campaign",
    { description: "Detalle de una campaña + desglose en vivo de su cola de mensajes.", inputSchema: { campaign_id: z.string() } },
    wrap((a: { campaign_id: string }) => getCampaign(a.campaign_id)));

  // ── Monitoreo ─────────────────────────────────────────────────────────────
  server.registerTool("queue_status",
    { description: "Estado global de la cola de mensajes (pending/sent/failed...).", inputSchema: {} },
    wrap(() => queueStatus()));

  server.registerTool("campaign_stats",
    { description: "Métricas de una campaña: cola por status y engagement email (eventos y leads únicos de opens/clics/rebotes vía metadata.campaign_id). Los seeds internos quedan EXCLUIDOS por defecto (DEC-023 gate D; by_trigger siempre muestra el desglose completo); include_seed=true los reincorpora solo como evidencia. WA no es atribuible por campaña todavía.", inputSchema: { campaign_id: z.string(), include_seed: z.boolean().optional().describe("Default false: excluye seeds (triggered_by=seed_internal o lead SEED). true solo para auditar evidencia histórica.") } },
    wrap((a: { campaign_id: string; include_seed?: boolean }) => campaignStats(a.campaign_id, a.include_seed ?? false)));

  // ── Automations / secuencias (sólo borrador; activar/enrolar es humano) ────
  server.registerTool("list_automations",
    { description: "Lista las automations/secuencias.", inputSchema: {} },
    wrap(() => listAutomations()));

  server.registerTool("get_automation",
    { description: "Devuelve una automation completa (incluye su flow).", inputSchema: { id: z.string() } },
    wrap((a: { id: string }) => getAutomation(a.id)));

  server.registerTool("create_automation",
    { description: "Crea una automation en borrador con un nodo trigger inicial.", inputSchema: { name: z.string() } },
    wrap(createAutomation));

  server.registerTool("update_automation",
    {
      description: "Actualiza nombre/flow de una automation y valida el flujo. NO la activa ni enrola leads (eso lo hace un humano porque dispara envíos).",
      inputSchema: {
        id: z.string(),
        name: z.string().optional(),
        flow: z.object({ nodes: z.array(z.any()), edges: z.array(z.any()) }).optional(),
      },
    },
    wrap(updateAutomation));

  // ── Lecturas del CRM (leads, inbox, reportes, salud) — solo lectura ────────
  server.registerTool("search_leads",
    {
      description: "Busca leads por texto (nombre/email/teléfono) y filtros (segmento, etapa, ciudad, especialización, flags de canal). Solo lectura.",
      inputSchema: {
        q: z.string().optional(),
        segment: z.enum(["SUPER_HOT", "HOT", "WARM", "COLD"]).optional(),
        stage: z.string().optional(),
        city: z.string().optional(),
        specialization: z.string().optional(),
        can_email: z.boolean().optional(),
        can_whatsapp: z.boolean().optional(),
        limit: z.number().int().optional().describe("Default 20, máx 100."),
      },
    },
    wrap(searchLeads));

  server.registerTool("get_lead",
    {
      description: "Devuelve un lead (por lead_id, email o phone) con sus últimos 10 eventos y tareas abiertas. Solo lectura.",
      inputSchema: { lead_id: z.string().optional(), email: z.string().optional(), phone: z.string().optional() },
    },
    wrap(getLead));

  server.registerTool("lead_timeline",
    {
      description: "Timeline completo de eventos (lead_events) de un lead, más reciente primero. Solo lectura.",
      inputSchema: { lead_id: z.string(), limit: z.number().int().optional().describe("Default 50, máx 200.") },
    },
    wrap(leadTimeline));

  server.registerTool("inbox_threads",
    {
      description: "Hilos del inbox unificado (misma RPC que el dashboard): último inbound/outbound, unread, ventana de 24h (last_wa_reply_at), flags de canal. Solo lectura.",
      inputSchema: { limit: z.number().int().optional().describe("Default 20, máx 100.") },
    },
    wrap(inboxThreads));

  server.registerTool("get_conversation",
    {
      description: "Conversación completa de un lead (burbujas con receipts) + estado calculado de la ventana de 24h de Meta (open/expires_at). Solo lectura.",
      inputSchema: { lead_id: z.string() },
    },
    wrap(getConversation));

  server.registerTool("get_report",
    {
      description: "Reportes agregados del CRM: funnel (leads por etapa), channel_stats (enviado/entregado/abierto/click/respuesta/fallo por canal), activity_daily (outbound/inbound por día), quality_summary (calidad de datos de leads). Solo lectura. Los leads SEED quedan EXCLUIDOS por defecto (DEC-023 gate D); include_seed=true los reincorpora solo como evidencia.",
      inputSchema: {
        report: z.enum(["funnel", "channel_stats", "activity_daily", "quality_summary"]),
        days: z.number().int().optional().describe("Ventana en días para channel_stats (default 30) y activity_daily (default 14)."),
        include_seed: z.boolean().optional().describe("Default false: excluye leads SEED. true solo para auditar evidencia histórica; jamás para métricas de negocio."),
      },
    },
    wrap(getReport));

  server.registerTool("agent_health",
    {
      description: "Incidentes del watchdog de los agentes WhatsApp (agent_health_incidents): canary_down, wa_no_reply, colas atascadas, rachas de fallos. Incluye conteo de abiertos ahora. Solo lectura.",
      inputSchema: { status: z.enum(["open", "notified", "resolved"]).optional(), limit: z.number().int().optional().describe("Default 20, máx 100.") },
    },
    wrap(agentHealth));

  // ── Escrituras acotadas sobre leads (jamás tocan message_queue ni envían) ──
  server.registerTool("update_lead_stage",
    {
      description: "Mueve un lead de etapa del pipeline (valida contra pipeline_stages). Misma semántica que el tablero: update + evento stage_changed auditado.",
      inputSchema: { lead_id: z.string(), stage: z.string().describe("Clave de etapa, p.ej. new/contacted/engaged/qualified/converted/lost.") },
    },
    wrap(updateLeadStage));

  server.registerTool("update_lead",
    {
      description: "Edita campos de perfil de un lead (whitelist: full_name, first_name, city, country, specialization, marketing_segment). Consentimiento: solo puede REVOCAR canales (revoke_can_email/revoke_can_whatsapp), jamás habilitarlos.",
      inputSchema: {
        lead_id: z.string(),
        fields: z.record(z.string()).optional(),
        revoke_can_email: z.boolean().optional(),
        revoke_can_whatsapp: z.boolean().optional(),
      },
    },
    wrap(updateLead));

  server.registerTool("add_lead_note",
    { description: "Agrega una nota interna a un lead (tabla lead_notes, visible en el dashboard).", inputSchema: { lead_id: z.string(), body: z.string().min(1) } },
    wrap(addLeadNote));

  server.registerTool("create_lead_task",
    {
      description: "Crea una tarea (status open) para un lead, con vencimiento opcional.",
      inputSchema: { lead_id: z.string(), title: z.string().min(1), description: z.string().optional(), due_at: z.string().optional().describe("ISO 8601") },
    },
    wrap(createLeadTask));

  server.registerTool("complete_lead_task",
    { description: "Completa una tarea (o la reabre con reopen=true).", inputSchema: { task_id: z.string(), reopen: z.boolean().optional() } },
    wrap(completeLeadTask));

  server.registerTool("set_agent_paused",
    {
      description: "Pausa (paused=true) o reanuda (paused=false) el agente IA comercial para un lead concreto. Auditado en lead_events. Pausar = el agente registra inbound pero no responde.",
      inputSchema: { lead_id: z.string(), paused: z.boolean(), reason: z.string().optional() },
    },
    wrap(setAgentPaused));

  // ── Prueba (única vía de envío real del MCP, a allowlist) ──────────────────
  server.registerTool("send_test",
    {
      description: "Envía UN email de prueba real a una dirección de la allowlist (vía SES). Único tool del MCP que envía. Requiere que exista un lead con ese email.",
      inputSchema: { template_key: z.string(), to_address: z.string(), payload: z.record(z.any()).optional() },
    },
    wrap(sendTest));

  return server;
}
