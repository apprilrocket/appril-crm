import { db, WORKSPACE_ID } from "../db.js";

/** Estado global de la cola (últimos N días) — diagnóstico rápido. */
export async function queueStatus() {
  const statuses = ["pending", "sending", "sent", "failed", "cancelled", "skipped"];
  const out: Record<string, number> = {};
  await Promise.all(
    statuses.map(async (s) => {
      const { count } = await db
        .from("message_queue")
        .select("id", { count: "exact", head: true })
        .eq("workspace_id", WORKSPACE_ID)
        .eq("status", s);
      if (count) out[s] = count;
    }),
  );
  return out;
}

/** Métricas de engagement de una campaña a partir de lead_events. */
export async function campaignStats(campaign_id: string) {
  // Mensajes de la campaña
  const { data: msgs, error } = await db
    .from("message_queue")
    .select("id, status, channel")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("campaign_id", campaign_id);
  if (error) throw new Error(error.message);
  const rows = msgs ?? [];
  const byStatus: Record<string, number> = {};
  for (const m of rows) byStatus[m.status] = (byStatus[m.status] ?? 0) + 1;

  // Eventos de engagement (opened/clicked/bounced) por template/campaña:
  // se cuentan vía lead_events para los leads contactados por esta campaña.
  const ids = rows.map((m) => m.id);
  let opened = 0, clicked = 0, bounced = 0;
  if (ids.length) {
    const events = ["email_opened", "email_clicked", "email_bounced", "wa_read", "wa_delivered"];
    const { data: ev } = await db
      .from("lead_events")
      .select("event_type, metadata")
      .eq("workspace_id", WORKSPACE_ID)
      .in("event_type", events)
      .limit(5000);
    const idset = new Set(ids);
    for (const e of ev ?? []) {
      const mid = (e.metadata as any)?.message_id;
      if (mid && idset.has(mid)) {
        if (e.event_type === "email_opened" || e.event_type === "wa_read") opened++;
        else if (e.event_type === "email_clicked") clicked++;
        else if (e.event_type === "email_bounced") bounced++;
      }
    }
  }
  return { total: rows.length, by_status: byStatus, opened, clicked, bounced };
}
