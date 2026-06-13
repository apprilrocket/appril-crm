'use server';

import { createClient } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { validateFlow, type Flow } from './flow-utils';

const DEFAULT_FLOW: Flow = {
  nodes: [
    {
      id: 'trigger-1',
      type: 'trigger',
      position: { x: 250, y: 40 },
      data: { triggerType: 'manual' }
    }
  ],
  edges: []
};

export async function createAutomation(formData: FormData) {
  const supabase = await createClient();
  const name = (formData.get('name') as string)?.trim();
  if (!name) return;

  const { data: me } = await supabase.from('crm_users').select('workspace_id').limit(1).single();
  if (!me?.workspace_id) return;

  const { data: automation } = await supabase
    .from('automations')
    .insert({
      workspace_id: me.workspace_id,
      name,
      trigger_type: 'manual',
      status: 'draft',
      flow: DEFAULT_FLOW
    })
    .select('id')
    .single();

  revalidatePath('/automations');
  if (automation) redirect(`/automations/${automation.id}`);
}

export async function saveAutomation(
  id: string,
  payload: { name: string; flow: Flow }
): Promise<{ errors?: string[]; ok?: boolean }> {
  const supabase = await createClient();

  // El trigger node es la fuente de verdad para trigger_type/config del enrollment automático
  const trigger = payload.flow.nodes.find(n => n.type === 'trigger');
  const td = trigger?.data ?? {};
  const triggerType = ['manual', 'event', 'stage', 'segment_match'].includes(td.triggerType)
    ? td.triggerType
    : 'manual';

  const { error } = await supabase
    .from('automations')
    .update({
      name: payload.name,
      flow: payload.flow,
      trigger_type: triggerType,
      trigger_config: {
        event_type: td.eventType ?? null,
        stage: td.stage ?? null,
        segment: td.segment ?? null,
        allow_reenroll: !!td.allowReenroll
      },
      updated_at: new Date().toISOString()
    })
    .eq('id', id);

  if (error) return { errors: [error.message] };
  revalidatePath(`/automations/${id}`);
  revalidatePath('/automations');
  return { ok: true };
}

export async function setAutomationStatus(
  id: string,
  status: 'active' | 'paused' | 'draft' | 'archived'
): Promise<{ errors?: string[]; ok?: boolean }> {
  const supabase = await createClient();

  if (status === 'active') {
    const { data: a } = await supabase.from('automations').select('flow').eq('id', id).single();
    if (!a) return { errors: ['Automatización no encontrada.'] };
    const errors = validateFlow(a.flow as Flow);
    if (errors.length) return { errors };
  }

  const { error } = await supabase.from('automations').update({ status }).eq('id', id);
  if (error) return { errors: [error.message] };

  revalidatePath(`/automations/${id}`);
  revalidatePath('/automations');
  return { ok: true };
}

export async function enrollSegment(
  automationId: string,
  segment: string
): Promise<{ enrolled?: number; error?: string }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('enroll_segment_in_automation', {
    p_automation_id: automationId,
    p_segment: segment,
    p_limit: 1000
  });
  if (error) return { error: error.message };
  revalidatePath(`/automations/${automationId}`);
  return { enrolled: data ?? 0 };
}
