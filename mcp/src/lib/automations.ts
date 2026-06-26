import { db, WORKSPACE_ID } from "../db.js";
import { config } from "../config.js";
import { GuardrailError } from "../guardrails.js";

/**
 * Flow por defecto: un único nodo trigger (igual que createAutomation del CRM).
 */
const DEFAULT_FLOW = {
  nodes: [{ id: "trigger", type: "trigger", position: { x: 250, y: 40 }, data: { triggerType: "manual" } }],
  edges: [],
};

type FlowNode = { id: string; type: string; position: { x: number; y: number }; data: Record<string, any> };
type Flow = { nodes: FlowNode[]; edges: any[] };

export async function listAutomations() {
  const { data, error } = await db
    .from("automations")
    .select("id, name, trigger_type, status, created_at")
    .eq("workspace_id", WORKSPACE_ID)
    .order("created_at", { ascending: false });
  if (error) throw new Error(error.message);
  return data;
}

export async function getAutomation(id: string) {
  const { data, error } = await db
    .from("automations")
    .select("*")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error("Automation no encontrada.");
  return data;
}

export async function createAutomation(args: { name: string }) {
  if (!args.name.trim()) throw new GuardrailError("La automation necesita nombre.");
  const { data, error } = await db
    .from("automations")
    .insert({
      workspace_id: WORKSPACE_ID,
      name: args.name.trim(),
      trigger_type: "manual",
      status: "draft",
      flow: DEFAULT_FLOW,
      created_by: config.serviceUserId,
    })
    .select("id, name, status")
    .single();
  if (error) throw new Error(error.message);
  return data;
}

/**
 * Valida un flow como hace flow-utils.validateFlow() antes de activar.
 * Devuelve lista de errores (vacía = válido).
 */
export function validateFlow(flow: Flow): string[] {
  const errors: string[] = [];
  const nodes = flow?.nodes ?? [];
  const edges = flow?.edges ?? [];
  const triggers = nodes.filter((n) => n.type === "trigger");
  if (triggers.length !== 1) errors.push("Debe haber exactamente un nodo trigger.");
  for (const n of nodes) {
    if ((n.type === "send_email" || n.type === "send_whatsapp") && !n.data?.templateKey)
      errors.push(`El nodo de envío "${n.id}" no tiene templateKey.`);
    if (n.type === "condition") {
      if (!n.data?.kind) errors.push(`La condición "${n.id}" no tiene kind.`);
      const hasYes = edges.some((e) => e.source === n.id && e.sourceHandle === "yes");
      const hasNo = edges.some((e) => e.source === n.id && e.sourceHandle === "no");
      if (!hasYes || !hasNo) errors.push(`La condición "${n.id}" necesita ramas sí y no.`);
    }
    if (n.type === "goal" && !n.data?.kind) errors.push(`El goal "${n.id}" no tiene kind.`);
  }
  if (nodes.length > 1 && triggers[0]) {
    const connected = edges.some((e) => e.source === triggers[0].id);
    if (!connected) errors.push("El trigger no está conectado al flujo.");
  }
  return errors;
}

/**
 * Actualiza nombre/flow. Deriva trigger_type/trigger_config del nodo trigger
 * (igual que saveAutomation del CRM). NO activa la automation.
 */
export async function updateAutomation(args: { id: string; name?: string; flow?: Flow }) {
  const current = await getAutomation(args.id);
  const flow: Flow = args.flow ?? current.flow;
  const trigger = (flow?.nodes ?? []).find((n) => n.type === "trigger");
  const td = trigger?.data ?? {};
  const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
  if (args.name !== undefined) patch.name = args.name.trim();
  if (args.flow !== undefined) {
    patch.flow = flow;
    patch.trigger_type = td.triggerType ?? "manual";
    patch.trigger_config = {
      event_type: td.eventType ?? null,
      stage: td.stage ?? null,
      segment: td.segment ?? null,
      allow_reenroll: !!td.allowReenroll,
    };
  }
  const { data, error } = await db
    .from("automations")
    .update(patch)
    .eq("workspace_id", WORKSPACE_ID)
    .eq("id", args.id)
    .select("id, name, status, trigger_type")
    .single();
  if (error) throw new Error(error.message);

  const validation = args.flow ? validateFlow(flow) : [];
  return { ...data, validation_errors: validation, note: validation.length ? "El flow tiene errores; corrígelos antes de que un humano lo active." : "Flow válido. La activación y el enrolamiento son acciones HUMANAS (disparan envíos)." };
}
