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

/** Métricas de engagement de una campaña a partir de lead_events.
 *
 * Atribución (DEC-023 gate b): el ses-webhook escribe `metadata.campaign_id` en
 * los eventos email_opened/email_clicked/email_bounced — ese es el join. El match
 * anterior por `metadata.message_id` nunca ocurría (la clave no existe en ningún
 * evento) y la tool reportaba 0 siempre. Los eventos wa_delivered/wa_read no
 * llevan atribución de campaña en metadata, así que no son contabilizables aquí.
 *
 * Regla SEED (DEC-023 gate D): los seeds internos (message_queue.triggered_by =
 * 'seed_internal' o leads_master.marketing_segment = 'SEED') quedan EXCLUIDOS
 * por defecto de totales y engagement; solo entran con include_seed=true.
 * by_trigger siempre muestra el desglose completo (evidencia histórica).
 */
export async function campaignStats(campaign_id: string, include_seed = false) {
  // Mensajes de la campaña (triggered_by separa lote real vs seeds internos)
  const { data: msgs, error } = await db
    .from("message_queue")
    .select("id, status, channel, triggered_by, lead_id")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("campaign_id", campaign_id);
  if (error) throw new Error(error.message);
  const rows = msgs ?? [];

  // Leads SEED entre los destinatarios (para excluirlos también del engagement)
  const leadIds = [...new Set(rows.map((m) => m.lead_id).filter(Boolean))];
  const seedLeads = new Set<string>();
  if (leadIds.length) {
    const { data: seeds } = await db
      .from("leads_master")
      .select("id")
      .eq("workspace_id", WORKSPACE_ID)
      .eq("marketing_segment", "SEED")
      .in("id", leadIds);
    for (const s of seeds ?? []) seedLeads.add(s.id);
  }
  const isSeedRow = (m: { triggered_by: string | null; lead_id: string | null }) =>
    m.triggered_by === "seed_internal" || (m.lead_id != null && seedLeads.has(m.lead_id));

  const byStatus: Record<string, number> = {};
  const byTrigger: Record<string, number> = {};
  let seedExcluded = 0;
  for (const m of rows) {
    const t = m.triggered_by ?? "desconocido";
    byTrigger[t] = (byTrigger[t] ?? 0) + 1;
    if (!include_seed && isSeedRow(m)) { seedExcluded++; continue; }
    byStatus[m.status] = (byStatus[m.status] ?? 0) + 1;
  }
  const total = include_seed ? rows.length : rows.length - seedExcluded;

  const { data: ev, error: evErr } = await db
    .from("lead_events")
    .select("event_type, lead_id")
    .eq("workspace_id", WORKSPACE_ID)
    .eq("metadata->>campaign_id", campaign_id)
    .in("event_type", ["email_opened", "email_clicked", "email_bounced"])
    .limit(5000);
  if (evErr) throw new Error(evErr.message);

  let opened = 0, clicked = 0, bounced = 0;
  const openedLeads = new Set<string>(), clickedLeads = new Set<string>(), bouncedLeads = new Set<string>();
  for (const e of ev ?? []) {
    if (!include_seed && e.lead_id && seedLeads.has(e.lead_id)) continue;
    if (e.event_type === "email_opened") { opened++; if (e.lead_id) openedLeads.add(e.lead_id); }
    else if (e.event_type === "email_clicked") { clicked++; if (e.lead_id) clickedLeads.add(e.lead_id); }
    else if (e.event_type === "email_bounced") { bounced++; if (e.lead_id) bouncedLeads.add(e.lead_id); }
  }
  return {
    include_seed,
    total,
    seed_excluded: include_seed ? 0 : seedExcluded,
    by_status: byStatus,
    by_trigger: byTrigger,
    opened, clicked, bounced,
    opened_leads: openedLeads.size,
    clicked_leads: clickedLeads.size,
    bounced_leads: bouncedLeads.size,
  };
}
