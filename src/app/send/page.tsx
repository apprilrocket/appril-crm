import { createClient } from '@/lib/supabase/server';
import { SendForm } from './SendForm';

export const dynamic = 'force-dynamic';

export default async function SendPage() {
  const supabase = await createClient();

  const [{ data: templates }, { count: pending }, { count: sent24h }, { count: failed24h }] = await Promise.all([
    supabase.from('message_templates').select('template_key, name, channel').eq('status', 'active'),
    supabase.from('message_queue').select('*', { count: 'exact', head: true }).eq('status', 'pending'),
    supabase.from('message_queue').select('*', { count: 'exact', head: true }).eq('status', 'sent').gte('sent_at', new Date(Date.now() - 86400000).toISOString()),
    supabase.from('message_queue').select('*', { count: 'exact', head: true }).eq('status', 'failed').gte('created_at', new Date(Date.now() - 86400000).toISOString())
  ]);

  return (
    <div className="p-8 max-w-3xl">
      <h1 className="text-2xl font-semibold text-neutral-900">Envío manual</h1>
      <p className="text-sm text-neutral-500 mt-1">
        Encola un envío a un lead específico. El Sender Lambda lo despacha en su próximo ciclo.
      </p>

      <div className="grid grid-cols-3 gap-3 mt-6">
        <Stat label="Pendientes en cola" value={pending ?? 0} />
        <Stat label="Enviados últ. 24h" value={sent24h ?? 0} color="text-emerald-700" />
        <Stat label="Fallidos últ. 24h" value={failed24h ?? 0} color="text-red-700" />
      </div>

      <div className="mt-6 bg-white border border-neutral-200 rounded-lg p-5">
        <SendForm templates={templates ?? []} />
      </div>
    </div>
  );
}

function Stat({ label, value, color = 'text-neutral-900' }: { label: string; value: number; color?: string }) {
  return (
    <div className="bg-white border border-neutral-200 rounded-lg p-4">
      <div className="text-xs text-neutral-500">{label}</div>
      <div className={`text-2xl font-semibold mt-1 ${color}`}>{value.toLocaleString('es-CO')}</div>
    </div>
  );
}
