import { db, WORKSPACE_ID } from "../db.js";
import { config } from "../config.js";
import { GuardrailError } from "../guardrails.js";

/** Audiencia total vs elegibles (tras guardas de canal). Usa la RPC canónica. */
export async function previewAudience(args: {
  channel: "email" | "whatsapp";
  segments?: string[];
  list_ids?: string[];
  allow_no_optin?: boolean;
}) {
  const { data, error } = await db.rpc("crm_preview_audience", {
    p_workspace_id: WORKSPACE_ID,
    p_channel: args.channel,
    p_segments: args.segments ?? [],
    p_list_ids: args.list_ids ?? [],
    p_allow_no_optin: args.allow_no_optin ?? false,
  });
  if (error) throw new Error(`${error.message} (¿está aplicada la migración mcp_campaign_launch?)`);
  const row = Array.isArray(data) ? data[0] : data;
  return { audience: Number(row?.audience ?? 0), eligible: Number(row?.eligible ?? 0) };
}

/** Crea una campaña en BORRADOR. Nunca la lanza. */
export async function createCampaign(args: {
  name: string;
  channel: "email" | "whatsapp";
  template_key: string;
  segments?: string[];
  list_ids?: string[];
  allow_no_optin?: boolean;
  description?: string;
}) {
  const segments = args.segments ?? [];
  const list_ids = args.list_ids ?? [];
  if (segments.length === 0 && list_ids.length === 0) {
    throw new GuardrailError("Selecciona al menos un segmento o una lista.");
  }

  // Valida template: existe, activo y del canal correcto.
  const { data: tpl } = await db
    .from("message_templates")
    .select("template_key, channel, status, variables")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("template_key", args.template_key)
    .maybeSingle();
  if (!tpl) throw new GuardrailError(`No existe el template "${args.template_key}".`);
  if (tpl.channel !== args.channel) throw new GuardrailError(`El template es de canal "${tpl.channel}", no "${args.channel}".`);
  if (tpl.status !== "active") throw new GuardrailError(`El template "${args.template_key}" no está activo (status=${tpl.status}).`);

  // El lanzamiento hidrata full_name y nombre (ver crm_launch_campaign). Avisa si
  // el template pide otras variables → saldrían vacías en el envío.
  // crm_launch_campaign hidrata estas claves en el payload de message_queue.
  // discovery_url / unsubscribe_url se agregaron en 20260629_1800_discovery_email_rewrite.sql.
  const SUPPORTED = new Set(["full_name", "nombre", "discovery_url", "unsubscribe_url"]);
  const unsupported = (Array.isArray(tpl.variables) ? (tpl.variables as string[]) : []).filter((v) => !SUPPORTED.has(v));
  const warning = unsupported.length
    ? `El template usa variables no hidratadas por el lanzamiento: ${unsupported.join(", ")}. Saldrían vacías. El lanzamiento sólo hidrata full_name, nombre, discovery_url y unsubscribe_url.`
    : undefined;

  const segment_filter: Record<string, unknown> = {};
  if (segments.length) segment_filter.marketing_segment = segments;
  if (list_ids.length) segment_filter.list_ids = list_ids;
  if (args.allow_no_optin) segment_filter.allow_no_optin = true;

  const { data, error } = await db
    .from("campaigns")
    .insert({
      workspace_id: WORKSPACE_ID,
      name: args.name,
      description: args.description ?? null,
      channel: args.channel,
      template_keys: [args.template_key],
      segment_filter,
      status: "draft",
      created_by: config.serviceUserId,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  const preview = await previewAudience({ channel: args.channel, segments, list_ids, allow_no_optin: args.allow_no_optin });
  return { id: data.id, status: "draft", preview, ...(warning ? { warning } : {}) };
}

/**
 * Programa una campaña: fija scheduled_at y marca launch_requested_at.
 * NO cambia status ni aprueba. Queda en 'draft' esperando aprobación HUMANA.
 */
export async function scheduleCampaign(args: { campaign_id: string; scheduled_at: string }) {
  const when = new Date(args.scheduled_at);
  if (isNaN(when.getTime())) throw new GuardrailError("scheduled_at no es una fecha ISO válida.");

  const { data: c } = await db
    .from("campaigns")
    .select("id, status, channel, template_keys, segment_filter")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("id", args.campaign_id)
    .maybeSingle();
  if (!c) throw new GuardrailError("Campaña no encontrada.");
  if (c.status !== "draft") throw new GuardrailError(`Sólo se puede programar una campaña en borrador (status actual=${c.status}).`);

  const { error } = await db
    .from("campaigns")
    .update({ scheduled_at: when.toISOString(), launch_requested_at: new Date().toISOString() })
    .eq("workspace_id", WORKSPACE_ID)
    .eq("id", args.campaign_id);
  if (error) throw new Error(error.message);

  return {
    campaign_id: args.campaign_id,
    scheduled_at: when.toISOString(),
    status: "draft",
    next_step:
      "Lista para revisión. Un HUMANO debe aprobarla (set approved_at + status='scheduled') para que el scheduler la lance. El MCP no aprueba ni envía.",
  };
}

export async function listCampaigns(args: { status?: string }) {
  let q = db
    .from("campaigns")
    .select("id, name, channel, status, scheduled_at, approved_at, started_at, stats, created_at")
    .eq("workspace_id", WORKSPACE_ID);
  if (args.status) q = q.eq("status", args.status);
  const { data, error } = await q.order("created_at", { ascending: false }).limit(50);
  if (error) throw new Error(error.message);
  return data;
}

export async function getCampaign(campaign_id: string) {
  const { data: c, error } = await db
    .from("campaigns")
    .select("*")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("id", campaign_id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!c) throw new Error("Campaña no encontrada.");

  // Desglose en vivo de la cola
  const statuses = ["pending", "sending", "sent", "failed", "cancelled", "skipped"];
  const queue: Record<string, number> = {};
  await Promise.all(
    statuses.map(async (s) => {
      const { count } = await db
        .from("message_queue")
        .select("id", { count: "exact", head: true })
        .eq("workspace_id", WORKSPACE_ID)
        .eq("campaign_id", campaign_id)
        .eq("status", s);
      if (count) queue[s] = count;
    }),
  );
  return { campaign: c, queue };
}
