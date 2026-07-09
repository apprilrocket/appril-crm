import { db, ws, WORKSPACE_ID } from "../db.js";
import { GuardrailError } from "../guardrails.js";
import { TRIGGERED_BY } from "../config.js";

/** Campos de perfil editables por el MCP. Los flags de consentimiento NO están aquí. */
const EDITABLE_FIELDS = ["full_name", "first_name", "city", "country", "specialization", "marketing_segment"] as const;
type EditableField = (typeof EDITABLE_FIELDS)[number];

async function assertLead(lead_id: string) {
  const { data, error } = await ws(
    db.from("leads_master").select("id, pipeline_stage, agent_paused, can_email, can_whatsapp"),
  )
    .eq("id", lead_id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error(`Lead ${lead_id} no existe en el workspace.`);
  return data as { id: string; pipeline_stage: string; agent_paused: boolean; can_email: boolean; can_whatsapp: boolean };
}

async function logEvent(lead_id: string, event_type: string, event_value: string | null, metadata: Record<string, unknown>) {
  await db.from("lead_events").insert({
    workspace_id: WORKSPACE_ID,
    lead_id,
    event_type,
    event_channel: null,
    event_value,
    metadata: { ...metadata, triggered_by: TRIGGERED_BY },
  });
}

/** Mueve un lead de etapa del pipeline. Misma semántica que el tablero (update + evento stage_changed). */
export async function updateLeadStage(input: { lead_id: string; stage: string }) {
  const lead = await assertLead(input.lead_id);
  const { data: stages } = await ws(db.from("pipeline_stages").select("key"));
  const valid = (stages ?? []).map((s) => (s as { key: string }).key);
  if (!valid.includes(input.stage)) {
    throw new GuardrailError(`Etapa inválida "${input.stage}". Válidas: ${valid.join(", ")}`);
  }
  if (lead.pipeline_stage === input.stage) return { ok: true, unchanged: true, stage: input.stage };

  const { error } = await ws(db.from("leads_master").update({ pipeline_stage: input.stage, updated_at: new Date().toISOString() }))
    .eq("id", input.lead_id);
  if (error) throw new Error(error.message);
  await logEvent(input.lead_id, "stage_changed", input.stage, { from: lead.pipeline_stage, to: input.stage });
  return { ok: true, from: lead.pipeline_stage, to: input.stage };
}

/** Edita campos de perfil (whitelist). Consentimiento: can_email/can_whatsapp SOLO pueden bajarse a false, nunca subirse. */
export async function updateLead(input: {
  lead_id: string;
  fields?: Partial<Record<EditableField, string>>;
  revoke_can_email?: boolean;
  revoke_can_whatsapp?: boolean;
}) {
  await assertLead(input.lead_id);
  const patch: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input.fields ?? {})) {
    if (!EDITABLE_FIELDS.includes(k as EditableField)) {
      throw new GuardrailError(`Campo no editable por el MCP: ${k}. Editables: ${EDITABLE_FIELDS.join(", ")}`);
    }
    patch[k] = v;
  }
  // Guardarraíl de consentimiento: el MCP puede REVOCAR canales (false), jamás habilitarlos.
  if (input.revoke_can_email) patch.can_email = false;
  if (input.revoke_can_whatsapp) patch.can_whatsapp = false;
  if (Object.keys(patch).length === 0) throw new Error("Nada que actualizar.");

  patch.updated_at = new Date().toISOString();
  const { error } = await ws(db.from("leads_master").update(patch)).eq("id", input.lead_id);
  if (error) throw new Error(error.message);
  await logEvent(input.lead_id, "lead_updated", null, { fields: Object.keys(patch).filter((k) => k !== "updated_at") });
  return { ok: true, updated: Object.keys(patch).filter((k) => k !== "updated_at") };
}

/** Agrega una nota al lead (misma tabla lead_notes del dashboard). */
export async function addLeadNote(input: { lead_id: string; body: string }) {
  await assertLead(input.lead_id);
  const { error } = await db.from("lead_notes").insert({
    workspace_id: WORKSPACE_ID,
    lead_id: input.lead_id,
    body: input.body.trim(),
  });
  if (error) throw new Error(error.message);
  return { ok: true };
}

/** Crea una tarea para un lead (status open, como el dashboard). */
export async function createLeadTask(input: { lead_id: string; title: string; description?: string; due_at?: string }) {
  await assertLead(input.lead_id);
  const { data, error } = await db
    .from("lead_tasks")
    .insert({
      workspace_id: WORKSPACE_ID,
      lead_id: input.lead_id,
      title: input.title.trim(),
      description: input.description ?? null,
      status: "open",
      due_at: input.due_at ? new Date(input.due_at).toISOString() : null,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return { ok: true, task_id: data.id };
}

/** Completa (o reabre) una tarea. Misma semántica que el dashboard: status + completed_at. */
export async function completeLeadTask(input: { task_id: string; reopen?: boolean }) {
  const done = !input.reopen;
  const { data, error } = await ws(
    db.from("lead_tasks").update({ status: done ? "done" : "open", completed_at: done ? new Date().toISOString() : null }),
  )
    .eq("id", input.task_id)
    .select("id, title, status")
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error(`Tarea ${input.task_id} no existe en el workspace.`);
  return { ok: true, task: data };
}

/** Pausa o reanuda el agente IA comercial para un lead (agent_paused). Auditado en lead_events. */
export async function setAgentPaused(input: { lead_id: string; paused: boolean; reason?: string }) {
  const lead = await assertLead(input.lead_id);
  if (lead.agent_paused === input.paused) return { ok: true, unchanged: true, agent_paused: input.paused };
  const { error } = await ws(db.from("leads_master").update({ agent_paused: input.paused })).eq("id", input.lead_id);
  if (error) throw new Error(error.message);
  await logEvent(input.lead_id, input.paused ? "agent_paused" : "agent_resumed", input.reason ?? null, {
    via: "mcp",
  });
  return { ok: true, agent_paused: input.paused };
}
