'use server';

import { createClient } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export type TemplatePayload = {
  name: string;
  channel: string;
  status: string;
  subject?: string;
  html_body?: string;
  text_body?: string;
  wa_template_name?: string;
  wa_language?: string;
};

export async function saveTemplate(
  id: string | null,
  data: TemplatePayload
): Promise<{ ok: true } | { error: string }> {
  const supabase = await createClient();

  const { data: user } = await supabase
    .from('crm_users')
    .select('workspace_id')
    .limit(1)
    .single();

  if (!user?.workspace_id) return { error: 'No se encontró workspace' };

  if (id) {
    const { error } = await supabase
      .from('message_templates')
      .update({ ...data, updated_at: new Date().toISOString() })
      .eq('id', id);
    if (error) return { error: error.message };
  } else {
    // Genera template_key único desde el nombre
    const base = data.name
      .toLowerCase()
      .normalize('NFD').replace(/[̀-ͯ]/g, '') // quita tildes
      .replace(/[^a-z0-9]+/g, '_')
      .replace(/^_|_$/g, '')
      .slice(0, 40);
    const template_key = `${base}_${Date.now()}`;

    const { error } = await supabase.from('message_templates').insert({
      workspace_id: user.workspace_id,
      template_key,
      ...data,
    });
    if (error) return { error: error.message };
  }

  revalidatePath('/templates');
  return { ok: true };
}

export async function deleteTemplate(id: string): Promise<{ ok: true } | { error: string }> {
  const supabase = await createClient();
  const { error } = await supabase.from('message_templates').delete().eq('id', id);
  if (error) return { error: error.message };
  revalidatePath('/templates');
  return { ok: true };
}
