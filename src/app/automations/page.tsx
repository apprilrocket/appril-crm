import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { Workflow, Plus, Zap, Trophy, CheckCircle2 } from 'lucide-react';
import { createAutomation } from './actions';
import { relativeTime } from '@/lib/utils';

export const dynamic = 'force-dynamic';

const STATUS_STYLE: Record<string, string> = {
  active: 'bg-emerald-100 text-emerald-800',
  draft: 'bg-neutral-100 text-neutral-600',
  paused: 'bg-amber-100 text-amber-800',
  archived: 'bg-neutral-200 text-neutral-500'
};
const STATUS_LABEL: Record<string, string> = {
  active: 'Activa',
  draft: 'Borrador',
  paused: 'Pausada',
  archived: 'Archivada'
};

export default async function AutomationsPage() {
  const supabase = await createClient();

  const [{ data: automations }, { data: runStats }] = await Promise.all([
    supabase
      .from('automations')
      .select('id, name, description, status, trigger_type, updated_at, flow')
      .neq('status', 'archived')
      .order('updated_at', { ascending: false }),
    supabase.from('automation_runs').select('automation_id, status')
  ]);

  const stats = new Map<string, { active: number; converted: number; completed: number }>();
  for (const r of runStats ?? []) {
    const s = stats.get(r.automation_id) ?? { active: 0, converted: 0, completed: 0 };
    if (r.status === 'active') s.active++;
    else if (r.status === 'converted') s.converted++;
    else s.completed++;
    stats.set(r.automation_id, s);
  }

  return (
    <div className="p-8 max-w-5xl">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-neutral-900">Automatizaciones</h1>
          <p className="text-sm text-neutral-500 mt-1">
            Flujos multicanal que llevan a cada lead hasta la conversión, en piloto automático.
          </p>
        </div>
      </div>

      <form action={createAutomation} className="flex gap-2 mb-6 bg-white border border-neutral-200 rounded-lg p-3">
        <input
          name="name"
          required
          placeholder="Nombre de la nueva automatización, ej: Recuperación ex-pagadores"
          className="flex-1 px-3 py-2 text-sm border border-neutral-200 rounded-md"
        />
        <button type="submit" className="inline-flex items-center gap-1.5 px-3 py-2 bg-brand-600 hover:bg-brand-700 text-white text-sm font-medium rounded-md">
          <Plus size={14} /> Crear flujo
        </button>
      </form>

      <div className="space-y-3">
        {(automations ?? []).map(a => {
          const s = stats.get(a.id) ?? { active: 0, converted: 0, completed: 0 };
          const nodeCount = ((a.flow as any)?.nodes ?? []).length;
          return (
            <Link
              key={a.id}
              href={`/automations/${a.id}`}
              className="block bg-white border border-neutral-200 hover:border-brand-300 rounded-lg p-4 transition-colors"
            >
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="w-9 h-9 rounded-lg bg-brand-50 flex items-center justify-center">
                    <Workflow size={18} className="text-brand-600" />
                  </div>
                  <div>
                    <div className="font-medium text-neutral-900">{a.name}</div>
                    <div className="text-xs text-neutral-500">
                      {nodeCount} elementos · actualizada {relativeTime(a.updated_at)}
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-4 text-xs">
                  <span className="inline-flex items-center gap-1 text-neutral-600">
                    <Zap size={13} className="text-blue-500" /> {s.active} en curso
                  </span>
                  <span className="inline-flex items-center gap-1 text-neutral-600">
                    <Trophy size={13} className="text-amber-500" /> {s.converted} convertidos
                  </span>
                  <span className="inline-flex items-center gap-1 text-neutral-600">
                    <CheckCircle2 size={13} className="text-neutral-400" /> {s.completed} finalizados
                  </span>
                  <span className={`px-2 py-0.5 rounded font-medium ${STATUS_STYLE[a.status] ?? STATUS_STYLE.draft}`}>
                    {STATUS_LABEL[a.status] ?? a.status}
                  </span>
                </div>
              </div>
            </Link>
          );
        })}
        {(!automations || automations.length === 0) && (
          <div className="text-center py-16 text-neutral-400 text-sm border border-dashed border-neutral-200 rounded-lg">
            Sin automatizaciones todavía. Crea la primera arriba — por ejemplo, una secuencia
            de recuperación para leads HOT que no han respondido.
          </div>
        )}
      </div>
    </div>
  );
}
