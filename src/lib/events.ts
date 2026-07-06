// Traducción de event_type técnicos a lenguaje humano para el timeline y la actividad.
// Cada evento tiene: label legible, icono, tono visual y categoría para filtrar.

export type EventCategory = 'reply' | 'engagement' | 'outbound' | 'system';

type EventMeta = {
  label: string;
  icon: string;
  tone: 'urgent' | 'positive' | 'neutral' | 'negative';
  category: EventCategory;
};

const EVENT_META: Record<string, EventMeta> = {
  // Respuestas del lead — lo más valioso
  wa_reply:                  { label: 'Respondió por WhatsApp',        icon: '💬', tone: 'urgent',   category: 'reply' },
  email_replied:             { label: 'Respondió el email',            icon: '💬', tone: 'urgent',   category: 'reply' },
  contact_submitted:         { label: 'Llenó el formulario de contacto', icon: '📝', tone: 'urgent', category: 'reply' },
  discovery_form_submitted:  { label: 'Completó el formulario de discovery', icon: '📝', tone: 'urgent', category: 'reply' },

  // Engagement
  email_opened:              { label: 'Abrió el email',                icon: '👀', tone: 'positive', category: 'engagement' },
  email_clicked:             { label: 'Hizo click en el email',        icon: '🔗', tone: 'positive', category: 'engagement' },
  cta_clicked:               { label: 'Hizo click en el CTA',          icon: '🔗', tone: 'positive', category: 'engagement' },
  wa_read:                   { label: 'Leyó el WhatsApp',              icon: '👀', tone: 'positive', category: 'engagement' },
  result_viewed:             { label: 'Vio su resultado',              icon: '👀', tone: 'positive', category: 'engagement' },
  demo_created:              { label: 'Creó una demo',                 icon: '🎯', tone: 'positive', category: 'engagement' },

  // Salida (nuestros envíos)
  message_sent:              { label: 'Le enviamos un mensaje',        icon: '📤', tone: 'neutral',  category: 'outbound' },
  wa_sent:                   { label: 'WhatsApp enviado',              icon: '📤', tone: 'neutral',  category: 'outbound' },
  wa_delivered:              { label: 'WhatsApp entregado',            icon: '✅', tone: 'neutral',  category: 'outbound' },
  email_delivered:           { label: 'Email entregado',               icon: '✅', tone: 'neutral',  category: 'outbound' },
  wa_agent_reply:            { label: 'El agente le respondió',        icon: '🤖', tone: 'neutral',  category: 'outbound' },
  message_queued:            { label: 'Mensaje encolado',              icon: '⏳', tone: 'neutral',  category: 'outbound' },

  // Fallos
  wa_failed:                 { label: 'Falló el WhatsApp',             icon: '⚠️', tone: 'negative', category: 'outbound' },
  email_bounced:             { label: 'El email rebotó',               icon: '⚠️', tone: 'negative', category: 'outbound' },
  // El webhook SES escribe `email_complained` y `email_rejected` (no `email_complaint`).
  email_complained:          { label: 'Marcó el email como spam',      icon: '🚫', tone: 'negative', category: 'outbound' },
  email_rejected:            { label: 'SES rechazó el email',          icon: '⚠️', tone: 'negative', category: 'outbound' },
  unsubscribed:              { label: 'Se dio de baja',                icon: '🚫', tone: 'negative', category: 'outbound' },

  // Sistema / CRM
  stage_changed:             { label: 'Cambió de etapa',               icon: '➡️', tone: 'neutral',  category: 'system' },
  segment_changed:           { label: 'Cambió de segmento',            icon: '🏷️', tone: 'neutral',  category: 'system' },
  note_added:                { label: 'Nota agregada',                 icon: '📌', tone: 'neutral',  category: 'system' },
  automation_enrolled:       { label: 'Entró a una automatización',    icon: '⚙️', tone: 'neutral',  category: 'system' },
  automation_converted:      { label: 'Convirtió en la automatización 🏆', icon: '🏆', tone: 'positive', category: 'system' },
  automation_exited:         { label: 'Salió de la automatización',    icon: '⚙️', tone: 'neutral',  category: 'system' },
  escalated_to_human:        { label: 'Pasado a Mauricio',             icon: '🙋', tone: 'neutral',  category: 'system' },
  demo_callback_sent:        { label: 'El doctor tocó la demo',        icon: '🎯', tone: 'positive', category: 'system' },
};

const FALLBACK: EventMeta = { label: '', icon: '·', tone: 'neutral', category: 'system' };

export function eventMeta(eventType: string): EventMeta {
  return EVENT_META[eventType] ?? { ...FALLBACK, label: eventType.replace(/_/g, ' ') };
}

// Describe un evento con su contexto: qué template, qué dijo, qué error
export function eventDetail(e: { event_type: string; event_value: string | null; metadata: any }): string | null {
  const v = e.event_value;
  switch (e.event_type) {
    case 'message_sent':
    case 'wa_sent':
      return v ? `Template: ${v}` : null;
    case 'wa_reply':
    case 'email_replied':
    case 'wa_agent_reply':
      return v ? `"${v}"` : null;
    case 'wa_failed': {
      const err = e.metadata?.errors?.[0];
      return err?.message ?? err?.title ?? 'Error de entrega de WhatsApp';
    }
    case 'stage_changed':
    case 'segment_changed':
    case 'automation_enrolled':
    case 'automation_converted':
    case 'automation_exited':
      return v ?? null;
    case 'cta_clicked':
    case 'result_viewed':
    case 'demo_created':
      return v && v !== e.event_type ? v : null;
    default:
      return null;
  }
}

export const EVENT_TONE_CLASSES: Record<EventMeta['tone'], string> = {
  urgent:   'bg-emerald-500',
  positive: 'bg-blue-500',
  neutral:  'bg-neutral-300',
  negative: 'bg-red-500',
};
