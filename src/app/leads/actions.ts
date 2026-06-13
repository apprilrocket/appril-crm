'use server';

import { createClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { applyLeadFilters, SEGMENTS, STAGES, type LeadsFilter } from '@/lib/leadFilters';

export type BulkTarget = { ids: string[] } | { filter: LeadsFilter };

export type BulkPatch = {
  pipeline_stage?: string;
  marketing_segment?: string;
  can_email?: boolean;
  can_whatsapp?: boolean;
};

// Hasta este número de leads afectados se registran eventos por lead;
// por encima, el insert masivo en lead_events haría el update demasiado lento.
const EVENT_LOG_LIMIT = 1000;

export async function bulkUpdateLeads(
  target: BulkTarget,
  patch: BulkPatch
): Promise<{ updated: number } | { error: string }> {
  const supabase = await createClient();

  // Valida el patch: solo campos permitidos, con valores conocidos
  const clean: Record<string, string | boolean> = {};
  if (patch.pipeline_stage !== undefined) {
    if (!STAGES.includes(patch.pipeline_stage)) return { error: 'Etapa inválida' };
    clean.pipeline_stage = patch.pipeline_stage;
  }
  if (patch.marketing_segment !== undefined) {
    if (!SEGMENTS.includes(patch.marketing_segment)) return { error: 'Segmento inválido' };
    clean.marketing_segment = patch.marketing_segment;
  }
  if (patch.can_email !== undefined) clean.can_email = patch.can_email;
  if (patch.can_whatsapp !== undefined) clean.can_whatsapp = patch.can_whatsapp;
  if (Object.keys(clean).length === 0) return { error: 'Nada que actualizar' };

  if ('ids' in target && target.ids.length === 0) return { error: 'No hay leads seleccionados' };

  // Los ids van en el query string de PostgREST: en lotes para no exceder el límite de URL
  let rows: { id: string; workspace_id: string }[] = [];
  if ('ids' in target) {
    const CHUNK = 200;
    for (let i = 0; i < target.ids.length; i += CHUNK) {
      const { data, error } = await supabase
        .from('leads_master')
        .update(clean)
        .in('id', target.ids.slice(i, i + CHUNK))
        .select('id, workspace_id');
      if (error) return { error: error.message };
      rows.push(...(data ?? []));
    }
  } else {
    let q = supabase.from('leads_master').update(clean);
    q = applyLeadFilters(q, target.filter);
    const { data, error } = await q.select('id, workspace_id');
    if (error) return { error: error.message };
    rows = data ?? [];
  }

  // Registra el cambio en el timeline de cada lead (si el lote no es gigante)
  if (rows.length > 0 && rows.length <= EVENT_LOG_LIMIT) {
    const events = rows.flatMap(r => {
      const out: any[] = [];
      if (clean.pipeline_stage !== undefined) {
        out.push({
          workspace_id: r.workspace_id, lead_id: r.id,
          event_type: 'stage_changed', event_value: clean.pipeline_stage,
          metadata: { bulk: true },
        });
      }
      if (clean.marketing_segment !== undefined) {
        out.push({
          workspace_id: r.workspace_id, lead_id: r.id,
          event_type: 'segment_changed', event_value: clean.marketing_segment,
          metadata: { bulk: true },
        });
      }
      return out;
    });
    for (let i = 0; i < events.length; i += 500) {
      await supabase.from('lead_events').insert(events.slice(i, i + 500));
    }
  }

  revalidatePath('/leads');
  return { updated: rows.length };
}

// Borrado definitivo. Notas, tareas, cola y runs se borran en cascada;
// la analítica de discovery conserva sus filas y lead_events queda como historial huérfano.
export async function bulkDeleteLeads(
  target: BulkTarget
): Promise<{ deleted: number } | { error: string }> {
  const supabase = await createClient();

  if ('ids' in target) {
    if (target.ids.length === 0) return { error: 'No hay leads seleccionados' };
    const CHUNK = 200;
    let deleted = 0;
    for (let i = 0; i < target.ids.length; i += CHUNK) {
      const { data, error } = await supabase
        .from('leads_master')
        .delete()
        .in('id', target.ids.slice(i, i + CHUNK))
        .select('id');
      if (error) return { error: error.message };
      deleted += data?.length ?? 0;
    }
    revalidatePath('/leads');
    return { deleted };
  }

  // Borrado por filtro: exige al menos un filtro activo para no vaciar la base por accidente
  const f = target.filter;
  const hasFilter = !!(f.q || f.segment || f.stage || f.channel || f.warming || f.city || f.source || f.specialization || f.uncontacted || f.paying);
  if (!hasFilter) return { error: 'Para borrar todos los que coinciden necesitas al menos un filtro activo.' };

  let q = supabase.from('leads_master').delete();
  q = applyLeadFilters(q, f);
  const { data, error } = await q.select('id');
  if (error) return { error: error.message };
  revalidatePath('/leads');
  return { deleted: data?.length ?? 0 };
}

export async function countMatchingLeads(filter: LeadsFilter): Promise<number> {
  const supabase = await createClient();
  let q = supabase.from('leads_master').select('*', { count: 'exact', head: true });
  q = applyLeadFilters(q, filter);
  const { count } = await q;
  return count ?? 0;
}

export type CreateLeadState = { error?: string } | null;

export async function createLead(_prev: CreateLeadState, formData: FormData): Promise<CreateLeadState> {
  const supabase = await createClient();

  const full_name = (formData.get('full_name') as string)?.trim();
  const email = (formData.get('email') as string)?.trim().toLowerCase() || null;
  const phone = (formData.get('phone') as string)?.trim() || null;
  const city = (formData.get('city') as string)?.trim() || null;
  const source = (formData.get('source') as string)?.trim() || 'manual';
  const specialization = (formData.get('specialization') as string)?.trim() || null;
  const marketing_segment = (formData.get('marketing_segment') as string) || 'WARM';
  const pipeline_stage = (formData.get('pipeline_stage') as string) || 'new';
  const note = (formData.get('note') as string)?.trim();

  if (!full_name) return { error: 'El nombre es obligatorio.' };
  if (!email && !phone) return { error: 'Necesitas al menos email o teléfono para poder contactarlo.' };

  const { data: me } = await supabase.from('crm_users').select('workspace_id').limit(1).single();
  if (!me?.workspace_id) return { error: 'No se pudo resolver tu workspace.' };

  if (email) {
    const { data: dup } = await supabase
      .from('leads_master')
      .select('id')
      .eq('email_normalized', email)
      .limit(1)
      .maybeSingle();
    if (dup) return { error: 'Ya existe un lead con ese email.' };
  }

  const { data: lead, error } = await supabase
    .from('leads_master')
    .insert({
      workspace_id: me.workspace_id,
      full_name,
      email,
      email_normalized: email,
      phone,
      city,
      source,
      specialization,
      marketing_segment,
      pipeline_stage,
      can_email: !!email,
      can_whatsapp: !!phone
    })
    .select('id')
    .single();

  if (error || !lead) return { error: error?.message ?? 'Error creando el lead.' };

  await supabase.from('lead_events').insert({
    workspace_id: me.workspace_id,
    lead_id: lead.id,
    event_type: 'lead_created',
    event_value: source
  });

  if (note) {
    await supabase.from('lead_notes').insert({ workspace_id: me.workspace_id, lead_id: lead.id, body: note });
  }

  revalidatePath('/leads');
  redirect(`/leads/${lead.id}`);
}
