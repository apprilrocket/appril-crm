'use server';

import { createClient } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export async function updateLeadStage(
  leadId: string,
  newStage: string
): Promise<{ ok: true } | { error: string }> {
  const supabase = await createClient();

  // Obtiene workspace_id del lead actual
  const { data: lead } = await supabase
    .from('leads_master')
    .select('workspace_id, pipeline_stage')
    .eq('id', leadId)
    .single();

  if (!lead) return { error: 'Lead no encontrado' };

  const { error } = await supabase
    .from('leads_master')
    .update({
      pipeline_stage: newStage,
      updated_at: new Date().toISOString(),
    })
    .eq('id', leadId);

  if (error) return { error: error.message };

  // Log en lead_events
  await supabase.from('lead_events').insert({
    workspace_id: lead.workspace_id,
    lead_id: leadId,
    event_type: 'stage_changed',
    event_channel: null,
    event_value: newStage,
    metadata: { from: lead.pipeline_stage, to: newStage },
  });

  revalidatePath('/pipeline');
  return { ok: true };
}
