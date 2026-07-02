import { db, WORKSPACE_ID } from "../db.js";
import { config } from "../config.js";
import { assertTestRecipient, GuardrailError } from "../guardrails.js";
import { getTemplate } from "./templates.js";
import { deriveNombre } from "./util.js";

/**
 * Envío de PRUEBA real (1 mensaje) a una dirección en la allowlist.
 * Es la ÚNICA vía por la que el MCP inserta en message_queue.
 * Sólo email (WhatsApp real requiere plantilla aprobada por Meta y se gestiona aparte).
 */
export async function sendTest(args: { template_key: string; to_address: string; payload?: Record<string, unknown> }) {
  const to = assertTestRecipient(args.to_address);

  const tpl = await getTemplate(args.template_key);
  if (tpl.channel !== "email") {
    throw new GuardrailError("send_test sólo soporta email. Para WhatsApp se necesita plantilla aprobada por Meta y un destinatario opt-in.");
  }

  // message_queue.lead_id es NOT NULL → necesitamos un lead con ese email.
  const { data: lead } = await db
    .from("leads_master")
    .select("id, full_name, first_name")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("email_normalized", to)
    .maybeSingle();
  if (!lead) throw new GuardrailError(`No hay un lead con email ${to}. Crea el contacto antes de enviar la prueba.`);

  const payload = args.payload ?? {
    full_name: lead.full_name ?? "Doctor(a)",
    nombre: deriveNombre(lead.first_name, lead.full_name),
  };

  // Avisa si el template pide variables que el payload no trae (saldrían vacías).
  const declared = Array.isArray(tpl.variables) ? (tpl.variables as string[]) : [];
  const missing = declared.filter((v) => !(v in payload));
  const warning = missing.length ? `Variables sin valor en el payload: ${missing.join(", ")} (saldrían vacías).` : undefined;

  const { data, error } = await db
    .from("message_queue")
    .insert({
      workspace_id: WORKSPACE_ID,
      lead_id: lead.id,
      template_key: args.template_key,
      channel: "email",
      to_address: to,
      payload,
      triggered_by: "mcp",
      created_by: config.serviceUserId,
      status: "pending",
      scheduled_at: new Date().toISOString(),
    })
    .select("id, to_address, template_key, status")
    .single();
  if (error) throw new Error(error.message);
  return { ...data, note: "Encolado. El sender (Lambda, cada ~2 min) lo enviará por SES real.", ...(warning ? { warning } : {}) };
}
