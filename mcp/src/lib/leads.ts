import { db, ws, WORKSPACE_ID } from "../db.js";

const LEAD_COLS =
  "id, full_name, first_name, email, phone, marketing_segment, pipeline_stage, engagement_score, " +
  "can_email, can_whatsapp, whatsapp_opted_in, agent_paused, city, country, specialization, source, " +
  "created_at, last_contacted_at, last_channel_touched, inbox_read_at";

export type SearchLeadsInput = {
  q?: string;
  segment?: string;
  stage?: string;
  city?: string;
  specialization?: string;
  can_email?: boolean;
  can_whatsapp?: boolean;
  limit?: number;
};

/** Búsqueda de leads con los filtros más usados del dashboard. Solo lectura. */
export async function searchLeads(input: SearchLeadsInput) {
  const limit = Math.min(Math.max(input.limit ?? 20, 1), 100);
  let q = ws(db.from("leads_master").select(LEAD_COLS, { count: "exact" }));
  if (input.q) {
    const term = input.q.replace(/[%,()]/g, "");
    q = q.or(`full_name.ilike.%${term}%,email.ilike.%${term}%,phone.ilike.%${term}%`);
  }
  if (input.segment) q = q.eq("marketing_segment", input.segment);
  if (input.stage) q = q.eq("pipeline_stage", input.stage);
  if (input.city) q = q.ilike("city", `%${input.city}%`);
  if (input.specialization) q = q.ilike("specialization", `%${input.specialization}%`);
  if (input.can_email !== undefined) q = q.eq("can_email", input.can_email);
  if (input.can_whatsapp !== undefined) q = q.eq("can_whatsapp", input.can_whatsapp);
  const { data, count, error } = await q.order("created_at", { ascending: false }).limit(limit);
  if (error) throw new Error(error.message);
  return { total_matching: count ?? 0, showing: data?.length ?? 0, leads: data ?? [] };
}

/** Un lead por id, email o teléfono, con sus últimos eventos y tareas abiertas. */
export async function getLead(input: { lead_id?: string; email?: string; phone?: string }) {
  let q = ws(db.from("leads_master").select(LEAD_COLS));
  if (input.lead_id) q = q.eq("id", input.lead_id);
  else if (input.email) {
    // email_normalized puede venir NULL en leads históricos/sintéticos.
    const e = input.email.trim().toLowerCase();
    q = q.or(`email_normalized.eq.${e},email.ilike.${e}`);
  } else if (input.phone) q = q.eq("phone", input.phone.trim());
  else throw new Error("Indica lead_id, email o phone.");
  const { data: lead, error } = await q.maybeSingle();
  if (error) throw new Error(error.message);
  if (!lead) return { found: false };

  const leadId = (lead as unknown as { id: string }).id;
  const [{ data: events }, { data: tasks }] = await Promise.all([
    ws(db.from("lead_events").select("event_type, event_value, created_at"))
      .eq("lead_id", leadId)
      .order("created_at", { ascending: false })
      .limit(10),
    db.from("lead_tasks").select("id, title, due_at, status")
      .eq("lead_id", leadId)
      .neq("status", "done")
      .limit(10),
  ]);
  return { found: true, lead, recent_events: events ?? [], open_tasks: tasks ?? [] };
}

/** Timeline completo (lead_events) de un lead, más reciente primero. */
export async function leadTimeline(input: { lead_id: string; limit?: number }) {
  const limit = Math.min(Math.max(input.limit ?? 50, 1), 200);
  const { data, error } = await ws(
    db.from("lead_events").select("event_type, event_channel, event_value, metadata, created_at"),
  )
    .eq("lead_id", input.lead_id)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw new Error(error.message);
  return { workspace_id: WORKSPACE_ID, lead_id: input.lead_id, events: data ?? [] };
}
