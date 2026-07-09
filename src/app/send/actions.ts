'use server';

import { createClient } from '@/lib/supabase/server';
import { E164_SQL_REGEX } from '@/lib/leadFilters';

// Envío puntual con guardas. Antes el form insertaba directo en message_queue
// desde el cliente, sin validar opt-out ni formato — este es el único camino
// permitido para el envío manual 1-a-1.
export async function sendSingleMessage(
  leadId: string,
  templateKey: string
): Promise<{ ok: true; to: string } | { error: string }> {
  const supabase = await createClient();

  const { data: u } = await supabase
    .from('crm_users')
    .select('workspace_id')
    .limit(1)
    .single();
  if (!u?.workspace_id) return { error: 'No se encontró workspace' };

  const { data: tpl } = await supabase
    .from('message_templates')
    .select('template_key, channel, active')
    .eq('template_key', templateKey)
    .single();
  if (!tpl) return { error: 'Template no encontrado' };
  if (tpl.active === false) return { error: 'El template está inactivo' };

  const { data: lead } = await supabase
    .from('leads_master')
    .select('id, full_name, email, phone, can_email, can_whatsapp')
    .eq('id', leadId)
    .single();
  if (!lead) return { error: 'Lead no encontrado' };

  // Guardas de canal: mismas reglas que las campañas (applyChannelGuards).
  let to: string;
  if (tpl.channel === 'email') {
    if (!lead.can_email) return { error: 'El lead tiene el email bloqueado (can_email=false).' };
    if (!lead.email || !lead.email.includes('@')) return { error: 'El lead no tiene email entregable.' };
    to = lead.email;
  } else {
    if (!lead.can_whatsapp) return { error: 'El lead tiene WhatsApp bloqueado (can_whatsapp=false).' };
    if (!lead.phone || !new RegExp(E164_SQL_REGEX).test(lead.phone)) {
      return { error: 'El teléfono del lead no es E.164 válido — jamás se "arregla" un número al enviar.' };
    }
    to = String(lead.phone).replace(/^\+/, '');
  }

  const { error } = await supabase.from('message_queue').insert({
    workspace_id: u.workspace_id,
    lead_id: lead.id,
    template_key: tpl.template_key,
    channel: tpl.channel,
    to_address: to,
    payload: { full_name: lead.full_name ?? 'Doctor' },
    triggered_by: 'manual',
    scheduled_at: new Date().toISOString(),
    status: 'pending',
  });
  if (error) return { error: error.message };

  return { ok: true, to };
}
