'use server';

import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';

// Guarda el remitente de email del workspace. RLS solo permite esto a admins.
// Cambiar el remitente devuelve el canal a 'pending_verification': el dominio
// debe verificarse en SES (DKIM/SPF) antes de activarse.
export async function updateEmailIntegration(formData: FormData) {
  const fromEmail = String(formData.get('from_email') ?? '').trim().toLowerCase();
  const fromName = String(formData.get('from_name') ?? '').trim();

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(fromEmail)) {
    return { error: 'Email de remitente inválido.' };
  }

  const supabase = await createClient();
  const { data: me } = await supabase.from('crm_users').select('workspace_id, role').limit(1).single();
  if (!me?.workspace_id) return { error: 'No se pudo resolver tu workspace.' };
  if (me.role !== 'admin') return { error: 'Solo un admin puede cambiar integraciones.' };

  const { data: current } = await supabase
    .from('workspace_integrations')
    .select('id, from_email, status')
    .eq('workspace_id', me.workspace_id)
    .eq('channel', 'email')
    .maybeSingle();

  // Mismo email ya activo → solo actualiza el nombre, no rompe la verificación.
  const keepActive = current?.status === 'active' && current?.from_email === fromEmail;

  const { error } = await supabase
    .from('workspace_integrations')
    .upsert(
      {
        workspace_id: me.workspace_id,
        channel: 'email',
        from_email: fromEmail,
        from_name: fromName || null,
        status: keepActive ? 'active' : 'pending_verification'
      },
      { onConflict: 'workspace_id,channel' }
    );

  if (error) return { error: error.message };
  revalidatePath('/settings');
  return { ok: true };
}
