// Recomendador de próxima acción por lead. Reglas en orden de prioridad.
// Lo usan el Pipeline (tarjetas), el detalle de lead y el home.

const WARMING_MS = 14 * 24 * 60 * 60 * 1000;
const STALE_MS = 5 * 24 * 60 * 60 * 1000;

export type ActionTone = 'urgent' | 'hot' | 'todo' | 'info';

export type NextAction = {
  text: string;
  tone: ActionTone;
  detail?: string;
};

export type LeadActionInput = {
  email: string | null;
  phone: string | null;
  engagement_score: number | null;
  last_engaged_at: string | null;
  last_contacted_at: string | null;
  pipeline_stage?: string | null;
  lastSentAt?: string | null;    // último mensaje nuestro (message_sent / wa_agent_reply)
  lastReplyAt?: string | null;   // última respuesta del lead
  lastReplyValue?: string | null;
  lastOpenAt?: string | null;    // último open/click sin respuesta
};

export function nextActionForLead(lead: LeadActionInput, now = Date.now()): NextAction | null {
  const stage = lead.pipeline_stage ?? 'new';
  if (stage === 'converted' || stage === 'lost') return null;

  const repliedAfterLastSend = lead.lastReplyAt &&
    (!lead.lastSentAt || new Date(lead.lastReplyAt) > new Date(lead.lastSentAt));
  if (repliedAfterLastSend) {
    return {
      text: '📞 Respondió — contactar YA',
      tone: 'urgent',
      detail: lead.lastReplyValue ? `Dijo: "${lead.lastReplyValue}"` : undefined,
    };
  }

  const openedAfterLastSend = lead.lastOpenAt && lead.lastSentAt &&
    new Date(lead.lastOpenAt) > new Date(lead.lastSentAt);
  if (openedAfterLastSend) {
    return {
      text: '👀 Abrió sin responder — enviar follow-up',
      tone: 'hot',
      detail: 'Mostró interés pero no contestó. Un segundo toque suele cerrar la brecha.',
    };
  }

  const warming = (lead.engagement_score ?? 0) >= 8 &&
    lead.last_engaged_at && now - new Date(lead.last_engaged_at).getTime() < WARMING_MS;
  if (warming) {
    return { text: '🔥 Caliente — proponer demo/llamada', tone: 'hot' };
  }

  if (!lead.email && !lead.phone) {
    return { text: '⚠️ Completar datos de contacto', tone: 'info' };
  }

  if (!lead.last_contacted_at && !lead.lastSentAt) {
    return { text: '✉️ Enviar primer contacto', tone: 'todo' };
  }

  const lastTouch = lead.lastSentAt
    ? new Date(lead.lastSentAt).getTime()
    : new Date(lead.last_contacted_at!).getTime();
  if (now - lastTouch > STALE_MS) {
    return { text: '⏰ Sin contacto hace +5 días — follow-up', tone: 'todo' };
  }

  return null;
}

export const ACTION_TONE_CLASSES: Record<ActionTone, string> = {
  urgent: 'bg-emerald-50 border-emerald-300 text-emerald-800',
  hot:    'bg-orange-50 border-orange-300 text-orange-800',
  todo:   'bg-amber-50 border-amber-200 text-amber-800',
  info:   'bg-neutral-50 border-neutral-200 text-neutral-600',
};
