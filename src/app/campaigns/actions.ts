'use server';

import { createClient } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';
import { E164_SQL_REGEX } from '@/lib/leadFilters';

export type CampaignPayload = {
  name: string;
  description?: string;
  channel: string;
  template_key: string;
  segments: string[];      // marketing_segment values
  list_ids?: string[];     // lead_lists.id — audiencia por lista
  allow_no_optin?: boolean; // WA: incluir leads sin opt-in registrado (decisión explícita)
  scheduled_at?: string;
};

export async function createCampaign(
  data: CampaignPayload
): Promise<{ id: string } | { error: string }> {
  const supabase = await createClient();

  const { data: user } = await supabase
    .from('crm_users')
    .select('workspace_id')
    .limit(1)
    .single();

  if (!user?.workspace_id) return { error: 'No se encontró workspace' };
  if (data.segments.length === 0 && (data.list_ids ?? []).length === 0) {
    return { error: 'Selecciona al menos un segmento o una lista' };
  }

  const segment_filter: Record<string, any> = {};
  if (data.segments.length > 0) segment_filter.marketing_segment = data.segments;
  if ((data.list_ids ?? []).length > 0) segment_filter.list_ids = data.list_ids;
  if (data.allow_no_optin) segment_filter.allow_no_optin = true;

  const { data: campaign, error } = await supabase
    .from('campaigns')
    .insert({
      workspace_id: user.workspace_id,
      name: data.name,
      description: data.description || null,
      channel: data.channel,
      template_keys: [data.template_key],
      segment_filter,
      status: 'draft',
      scheduled_at: data.scheduled_at || null,
    })
    .select('id')
    .single();

  if (error) return { error: error.message };

  revalidatePath('/campaigns');
  return { id: campaign.id };
}

// Audiencia base: segmentos y/o listas (sin guardas de canal todavía)
function audienceQuery(
  supabase: any,
  segments: string[],
  listIds: string[],
  select: string,
  opts?: { count?: boolean }
) {
  const needsJoin = listIds.length > 0;
  const fullSelect = needsJoin ? `${select}, lead_list_members!inner(list_id)` : select;
  let q = supabase
    .from('leads_master')
    .select(fullSelect, opts?.count ? { count: 'exact', head: true } : undefined);
  if (segments.length > 0) q = q.in('marketing_segment', segments);
  if (needsJoin) q = q.in('lead_list_members.list_id', listIds);
  return q;
}

// Guardas de canal. WhatsApp: SOLO teléfonos E.164 válidos — jamás se "arregla"
// un número agregándole indicativo. Email: solo entregables.
function applyChannelGuards(q: any, channel: string, requireOptin: boolean) {
  if (channel === 'email') {
    return q
      .eq('can_email', true)
      .not('email', 'is', null)
      .like('email', '%@%');
  }
  q = q
    .eq('can_whatsapp', true)
    .not('phone', 'is', null)
    .filter('phone', 'match', E164_SQL_REGEX);
  if (requireOptin) q = q.eq('whatsapp_opted_in', true);
  return q;
}

export async function launchCampaign(
  campaignId: string
): Promise<{ queued: number; excluded: number } | { error: string }> {
  const supabase = await createClient();

  // 1. Carga la campaña
  const { data: campaign } = await supabase
    .from('campaigns')
    .select('id, workspace_id, channel, template_keys, segment_filter, scheduled_at, status, approved_at')
    .eq('id', campaignId)
    .single();

  if (!campaign) return { error: 'Campaña no encontrada' };
  if (campaign.status !== 'draft') return { error: 'Solo se pueden lanzar campañas en borrador' };
  // Candado de aprobación humana: mismo requisito que crm_launch_campaign (vía MCP/SQL).
  // Ningún camino puede encolar masivos sin approved_at en la BD.
  if (!campaign.approved_at) {
    return { error: 'Falta aprobación humana: la campaña no tiene approved_at. Apruébala antes de lanzar.' };
  }

  const templateKey = campaign.template_keys[0];
  if (!templateKey) return { error: 'La campaña no tiene template asignado' };

  // 2. Audiencia + guardas
  const filter = (campaign.segment_filter ?? {}) as Record<string, any>;
  const segments: string[] = filter.marketing_segment ?? [];
  const listIds: string[] = filter.list_ids ?? [];
  const requireOptin = campaign.channel === 'whatsapp' && !filter.allow_no_optin;

  // Conteo de la audiencia total (sin guardas) para reportar excluidos
  const { count: audienceCount, error: audErr } = await audienceQuery(
    supabase, segments, listIds, 'id', { count: true }
  );
  if (audErr) return { error: audErr.message };

  let query = audienceQuery(supabase, segments, listIds, 'id, full_name, email, phone');
  query = applyChannelGuards(query, campaign.channel, requireOptin);

  const { data: leads, error: leadsErr } = await query;
  if (leadsErr) return { error: leadsErr.message };
  if (!leads || leads.length === 0) {
    return {
      error: campaign.channel === 'whatsapp'
        ? `Ningún lead elegible: de ${audienceCount ?? 0} en la audiencia, ninguno cumple teléfono E.164 válido + WhatsApp activo${requireOptin ? ' + opt-in registrado' : ''}. Revisa /quality.`
        : `Ningún lead elegible: de ${audienceCount ?? 0} en la audiencia, ninguno tiene email entregable.`,
    };
  }

  // 3. Construye filas para message_queue — el to_address va tal cual está
  //    en la base (ya validado E.164); para WA, Meta lo recibe sin '+'.
  const scheduledAt = campaign.scheduled_at ?? new Date().toISOString();

  const rows = (leads as any[]).map(lead => ({
    workspace_id: campaign.workspace_id,
    lead_id: lead.id,
    campaign_id: campaignId,
    template_key: templateKey,
    channel: campaign.channel,
    to_address: campaign.channel === 'email' ? lead.email : String(lead.phone).replace(/^\+/, ''),
    payload: { full_name: lead.full_name ?? 'Doctor' },
    triggered_by: 'campaign',
    scheduled_at: scheduledAt,
    status: 'pending',
  }));

  // 4. Inserta en lotes de 500
  const BATCH = 500;
  for (let i = 0; i < rows.length; i += BATCH) {
    const { error: insertErr } = await supabase
      .from('message_queue')
      .insert(rows.slice(i, i + BATCH));
    if (insertErr) return { error: `Error al encolar (lote ${i / BATCH + 1}): ${insertErr.message}` };
  }

  // 5. Actualiza estado de la campaña, con excluidos en stats
  const excluded = Math.max(0, (audienceCount ?? rows.length) - rows.length);
  await supabase
    .from('campaigns')
    .update({
      status: 'running',
      started_at: new Date().toISOString(),
      stats: {
        total: rows.length,
        queued: rows.length,
        sent: 0,
        failed: 0,
        audience: audienceCount ?? rows.length,
        excluded,
        optin_required: requireOptin,
      },
    })
    .eq('id', campaignId);

  revalidatePath('/campaigns');
  revalidatePath(`/campaigns/${campaignId}`);
  return { queued: rows.length, excluded };
}

export async function retryCampaignFailed(
  campaignId: string
): Promise<{ retried: number } | { error: string }> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('message_queue')
    .update({
      status: 'pending',
      attempts: 0,
      last_error: null,
      scheduled_at: new Date().toISOString(),
    })
    .eq('campaign_id', campaignId)
    .eq('status', 'failed')
    .select('id');

  if (error) return { error: error.message };

  revalidatePath(`/campaigns/${campaignId}`);
  revalidatePath('/campaigns');
  return { retried: data?.length ?? 0 };
}

// Alcance en vivo para el form: elegibles vs audiencia total
export async function countCampaignLeads(
  channel: string,
  segments: string[],
  listIds: string[] = [],
  allowNoOptin = false
): Promise<{ count: number; audience: number } | { error: string }> {
  const supabase = await createClient();

  const requireOptin = channel === 'whatsapp' && !allowNoOptin;

  const [{ count: audience, error: e1 }, { count, error: e2 }] = await Promise.all([
    audienceQuery(supabase, segments, listIds, 'id', { count: true }),
    applyChannelGuards(
      audienceQuery(supabase, segments, listIds, 'id', { count: true }),
      channel,
      requireOptin
    ),
  ]);

  if (e1 || e2) return { error: (e1 ?? e2)!.message };
  return { count: count ?? 0, audience: audience ?? 0 };
}
