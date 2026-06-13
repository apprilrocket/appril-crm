'use client';

import { useState, useTransition } from 'react';
import { createClient } from '@/lib/supabase/client';

type Template = { template_key: string; name: string; channel: string };

export function SendForm({ templates }: { templates: Template[] }) {
  const [search, setSearch] = useState('');
  const [results, setResults] = useState<any[]>([]);
  const [selected, setSelected] = useState<any | null>(null);
  const [templateKey, setTemplateKey] = useState('');
  const [pending, startTransition] = useTransition();
  const [feedback, setFeedback] = useState<string | null>(null);

  async function doSearch() {
    if (!search.trim()) return;
    const supabase = createClient();
    const { data } = await supabase
      .from('leads_master')
      .select('id, full_name, email, phone, can_email, can_whatsapp, marketing_segment')
      .or(`full_name.ilike.%${search}%,email.ilike.%${search}%,phone.ilike.%${search}%`)
      .limit(10);
    setResults(data ?? []);
  }

  async function enqueue() {
    if (!selected || !templateKey) return;
    const tpl = templates.find(t => t.template_key === templateKey);
    if (!tpl) return;
    const to = tpl.channel === 'email' ? selected.email : selected.phone;
    if (!to) { setFeedback('El lead no tiene dirección en ese canal.'); return; }

    startTransition(async () => {
      const supabase = createClient();
      const { data: u } = await supabase.from('crm_users').select('workspace_id').limit(1).single();
      const { error } = await supabase.from('message_queue').insert({
        workspace_id: u?.workspace_id,
        lead_id: selected.id,
        template_key: tpl.template_key,
        channel: tpl.channel,
        to_address: to,
        triggered_by: 'manual',
        scheduled_at: new Date().toISOString()
      });
      setFeedback(error ? `Error: ${error.message}` : `✓ Encolado para ${selected.full_name ?? to}`);
      setSelected(null);
      setTemplateKey('');
    });
  }

  return (
    <div className="space-y-4">
      <div>
        <label className="text-xs text-neutral-500">1. Buscar lead</label>
        <div className="flex gap-2 mt-1">
          <input
            value={search}
            onChange={e => setSearch(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && (e.preventDefault(), doSearch())}
            placeholder="nombre, email o teléfono"
            className="flex-1 px-3 py-2 text-sm border border-neutral-200 rounded-md"
          />
          <button onClick={doSearch} className="px-3 py-2 text-sm bg-neutral-900 text-white rounded-md hover:bg-neutral-800">
            Buscar
          </button>
        </div>
        {results.length > 0 && (
          <ul className="mt-2 border border-neutral-200 rounded-md divide-y divide-neutral-100 max-h-60 overflow-auto">
            {results.map(l => (
              <li key={l.id}>
                <button
                  onClick={() => { setSelected(l); setResults([]); setSearch(''); }}
                  className="w-full text-left px-3 py-2 text-sm hover:bg-neutral-50"
                >
                  <div className="font-medium text-neutral-900">{l.full_name ?? l.email ?? l.phone}</div>
                  <div className="text-xs text-neutral-500">{l.email ?? '—'} · {l.phone ?? '—'} · {l.marketing_segment ?? 'UNKNOWN'}</div>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      {selected && (
        <div className="bg-neutral-50 border border-neutral-200 rounded-md p-3">
          <div className="text-sm font-medium text-neutral-900">{selected.full_name ?? 'Sin nombre'}</div>
          <div className="text-xs text-neutral-500">{selected.email ?? '—'} · {selected.phone ?? '—'}</div>
          <div className="text-xs text-neutral-500 mt-1">
            Canales: {selected.can_email ? '✉ email' : ''} {selected.can_whatsapp ? 'WA' : ''}
            {!selected.can_email && !selected.can_whatsapp && <span className="text-red-600">bloqueado en todos los canales</span>}
          </div>
        </div>
      )}

      <div>
        <label className="text-xs text-neutral-500">2. Elegir template</label>
        <select
          value={templateKey}
          onChange={e => setTemplateKey(e.target.value)}
          className="w-full mt-1 px-3 py-2 text-sm border border-neutral-200 rounded-md bg-white"
        >
          <option value="">— Selecciona —</option>
          {templates.map(t => (
            <option key={t.template_key} value={t.template_key}>[{t.channel}] {t.name}</option>
          ))}
        </select>
        {templates.length === 0 && (
          <p className="text-xs text-neutral-500 mt-1">No hay templates activos.</p>
        )}
      </div>

      <button
        onClick={enqueue}
        disabled={!selected || !templateKey || pending}
        className="w-full bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white py-2 rounded-md text-sm font-medium"
      >
        {pending ? 'Encolando…' : 'Encolar envío'}
      </button>

      {feedback && (
        <div className="text-sm text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-md p-3">
          {feedback}
        </div>
      )}
    </div>
  );
}
