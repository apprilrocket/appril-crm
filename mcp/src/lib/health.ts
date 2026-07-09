import { db } from "../db.js";

/**
 * Incidentes del watchdog de agentes WA (agent_health_tick, pg_cron cada 10 min).
 * Solo lectura: el diagnóstico exacto viene en `details` (JSON del canario/scan).
 */
export async function agentHealth(input: { status?: "open" | "notified" | "resolved"; limit?: number }) {
  const limit = Math.min(Math.max(input.limit ?? 20, 1), 100);
  let q = db
    .from("agent_health_incidents")
    .select("id, source, incident_type, ref_id, details, status, created_at, notified_at, resolved_at");
  if (input.status) q = q.eq("status", input.status);
  const { data, error } = await q.order("created_at", { ascending: false }).limit(limit);
  if (error) throw new Error(error.message);

  const { count: openCount } = await db
    .from("agent_health_incidents")
    .select("id", { count: "exact", head: true })
    .eq("status", "open");
  return { open_now: openCount ?? 0, incidents: data ?? [] };
}
