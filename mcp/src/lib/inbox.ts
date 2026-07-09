import { db } from "../db.js";

/** Hilos del inbox (misma RPC que usa el dashboard): inbound ∪ outbound, excluye blasts. */
export async function inboxThreads(input: { limit?: number }) {
  const limit = Math.min(Math.max(input.limit ?? 20, 1), 100);
  const { data, error } = await db.rpc("inbox_threads", { p_limit: limit });
  if (error) throw new Error(error.message);
  return data ?? [];
}

/**
 * Conversación completa de un lead (misma RPC del dashboard) + estado de la
 * ventana de 24h de Meta calculado desde el último wa_reply.
 */
export async function getConversation(input: { lead_id: string }) {
  const [{ data: messages, error }, { data: lastReply }] = await Promise.all([
    db.rpc("conversation_messages", { p_lead_id: input.lead_id }),
    db.from("lead_events").select("created_at")
      .eq("lead_id", input.lead_id)
      .eq("event_type", "wa_reply")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  if (error) throw new Error(error.message);

  let wa_window: { open: boolean; last_inbound_at?: string; expires_at?: string } = { open: false };
  if (lastReply?.created_at) {
    const last = new Date(lastReply.created_at as string).getTime();
    const expires = last + 24 * 60 * 60 * 1000;
    wa_window = {
      open: Date.now() < expires,
      last_inbound_at: lastReply.created_at as string,
      expires_at: new Date(expires).toISOString(),
    };
  }
  return { lead_id: input.lead_id, wa_window, messages: messages ?? [] };
}
