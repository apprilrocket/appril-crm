'use client';

import { useState, useTransition } from 'react';
import { createClient } from '@/lib/supabase/client';
import { useRouter } from 'next/navigation';
import { Plus, Circle, CheckCircle2 } from 'lucide-react';
import { formatDate } from '@/lib/utils';

type Task = {
  id: string;
  title: string;
  status: string;
  due_at: string | null;
};

export function TasksCard({ leadId, tasks }: { leadId: string; tasks: Task[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [dueAt, setDueAt] = useState('');

  async function addTask() {
    if (!title.trim()) return;
    startTransition(async () => {
      const supabase = createClient();
      const { data: me } = await supabase.from('crm_users').select('workspace_id').limit(1).single();
      await supabase.from('lead_tasks').insert({
        workspace_id: me?.workspace_id,
        lead_id: leadId,
        title: title.trim(),
        status: 'open',
        due_at: dueAt ? new Date(dueAt).toISOString() : null
      });
      setTitle('');
      setDueAt('');
      setOpen(false);
      router.refresh();
    });
  }

  async function toggleTask(task: Task) {
    startTransition(async () => {
      const supabase = createClient();
      const done = task.status === 'done';
      await supabase
        .from('lead_tasks')
        .update({ status: done ? 'open' : 'done', completed_at: done ? null : new Date().toISOString() })
        .eq('id', task.id);
      router.refresh();
    });
  }

  const isOverdue = (t: Task) => t.status !== 'done' && t.due_at && new Date(t.due_at) < new Date();

  return (
    <section className="bg-white border border-neutral-200 rounded-lg p-5">
      <div className="flex items-center justify-between mb-2">
        <h2 className="text-sm font-semibold text-neutral-900">Tareas</h2>
        <button
          onClick={() => setOpen(!open)}
          className="inline-flex items-center gap-1 text-xs text-brand-600 hover:text-brand-700 font-medium"
        >
          <Plus size={12} /> Nueva
        </button>
      </div>

      {open && (
        <div className="mb-3 p-2.5 border border-neutral-200 rounded-md bg-neutral-50 space-y-2">
          <input
            value={title}
            onChange={e => setTitle(e.target.value)}
            placeholder="Ej: llamar para agendar demo"
            className="w-full px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white"
          />
          <div className="flex gap-2">
            <input
              type="date"
              value={dueAt}
              onChange={e => setDueAt(e.target.value)}
              className="flex-1 px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white"
            />
            <button
              onClick={addTask}
              disabled={!title.trim() || pending}
              className="px-3 py-1.5 bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white text-xs font-medium rounded-md"
            >
              Crear
            </button>
          </div>
        </div>
      )}

      {tasks.length > 0 ? (
        <ul className="text-sm space-y-1.5">
          {tasks.map(t => (
            <li key={t.id} className="flex items-start gap-2">
              <button onClick={() => toggleTask(t)} disabled={pending} className="mt-0.5 text-neutral-400 hover:text-emerald-600">
                {t.status === 'done' ? <CheckCircle2 size={15} className="text-emerald-600" /> : <Circle size={15} />}
              </button>
              <div className="flex-1">
                <span className={t.status === 'done' ? 'line-through text-neutral-400' : 'text-neutral-800'}>{t.title}</span>
                {t.due_at && (
                  <span className={`ml-2 text-xs ${isOverdue(t) ? 'text-red-600 font-medium' : 'text-neutral-400'}`}>
                    {isOverdue(t) ? '⚠ venció ' : ''}{formatDate(t.due_at)}
                  </span>
                )}
              </div>
            </li>
          ))}
        </ul>
      ) : (
        !open && <p className="text-sm text-neutral-500">Sin tareas. Crea una para no perder el seguimiento.</p>
      )}
    </section>
  );
}
