'use client';

import { useState, useTransition } from 'react';
import { createClient } from '@/lib/supabase/client';
import { useRouter } from 'next/navigation';
import { Send, FileText, CheckCircle2 } from 'lucide-react';

type Stage = { key: string; label: string; color: string | null };
type Template = { template_key: string; name: string; channel: string };

export function LeadActions({
  leadId, currentStage, stages, templates, canEmail, canWhatsapp, email, phone
}: {
  leadId: string;
  currentStage: string;
  stages: Stage[];
  templates: Template[];
  canEmail: boolean;
  canWhatsapp: boolean;
  email: string | null;
  phone: string | null;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [noteOpen, setNoteOpen] = useState(false);
  const [noteBody, setNoteBody] = useState('');
  const [sendOpen, setSendOpen] = useState(false);
  const [selectedTpl, setSelectedTpl] = useState('');
  const [feedback, setFeedback] = useState<string | null>(null);

  async function changeStage(newStage: string) {
    startTransition(async () => {
      const supabase = createClient();
      await supabase.from('leads_master').update({ pipeline_stage: newStage }).eq('id', leadId);
      await supabase.from('lead_events').insert({
        lead_id: leadId,
        event_type: 'stage_changed',
        event_value: newStage,
        workspace_id: (await getWsId(supabase))
      });
      router.refresh();
    });
  }

  async function saveNote() {
    if (!noteBody.trim()) return;
    startTransition(async () => {
      const supabase = createClient();
      const wsId = await getWsId(supabase);
      await supabase.from('lead_notes').insert({ lead_id: leadId, body: noteBody, workspace_id: wsId });
      setNoteBody('');
      setNoteOpen(false);
      router.refresh();
    });
  }

  async function enqueueSend() {
    if (!selectedTpl) return;
    const tpl = templates.find(t => t.template_key === selectedTpl);
    if (!tpl) return;
    const to = tpl.channel === 'email' ? email : phone;
    if (!to) { setFeedback('Sin dirección de destino para este canal.'); return; }

    startTransition(async () => {
      const supabase = createClient();
      const wsId = await getWsId(supabase);
      const { error } = await supabase.from('message_queue').insert({
        workspace_id: wsId,
        lead_id: leadId,
        template_key: tpl.template_key,
        channel: tpl.channel,
        to_address: to,
        triggered_by: 'manual',
        scheduled_at: new Date().toISOString()
      });
      setFeedback(error ? `Error: ${error.message}` : '✓ Encolado. El sender lo despacha en su próximo ciclo.');
      setSendOpen(false);
      router.refresh();
    });
  }

  return (
    <div className="bg-white border border-neutral-200 rounded-lg p-4 flex flex-wrap items-center gap-2">
      {/* Cambiar etapa */}
      <div className="flex items-center gap-2 text-sm">
        <span className="text-neutral-500">Mover a:</span>
        <select
          defaultValue={currentStage}
          onChange={(e) => changeStage(e.target.value)}
          disabled={pending}
          className="px-2 py-1 text-sm border border-neutral-200 rounded-md bg-white"
        >
          {stages.map(s => <option key={s.key} value={s.key}>{s.label}</option>)}
        </select>
      </div>

      <div className="w-px h-6 bg-neutral-200" />

      {/* Enviar mensaje */}
      <button
        onClick={() => setSendOpen(!sendOpen)}
        disabled={pending}
        className="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white rounded-md"
      >
        <Send size={14} /> Enviar mensaje
      </button>

      <button
        onClick={() => setNoteOpen(!noteOpen)}
        className="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm border border-neutral-200 hover:bg-neutral-50 rounded-md"
      >
        <FileText size={14} /> Nota
      </button>

      {(!canEmail || !canWhatsapp) && (
        <span className="text-xs text-neutral-400 ml-auto">
          {!canEmail && '✉ bloqueado'} {!canWhatsapp && '· WA bloqueado'}
        </span>
      )}

      {feedback && (
        <div className="w-full mt-2 text-sm flex items-center gap-1 text-emerald-700">
          <CheckCircle2 size={14} /> {feedback}
        </div>
      )}

      {sendOpen && (
        <div className="w-full mt-3 p-3 border border-neutral-200 rounded-md bg-neutral-50">
          <label className="text-xs text-neutral-500">Template</label>
          <div className="flex gap-2 mt-1">
            <select
              value={selectedTpl}
              onChange={e => setSelectedTpl(e.target.value)}
              className="flex-1 px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white"
            >
              <option value="">— Elegir template —</option>
              {templates.map(t => (
                <option key={t.template_key} value={t.template_key}>
                  [{t.channel}] {t.name}
                </option>
              ))}
            </select>
            <button onClick={enqueueSend} disabled={!selectedTpl || pending} className="px-3 py-1.5 bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white text-sm rounded-md">
              Encolar
            </button>
          </div>
          {templates.length === 0 && (
            <p className="text-xs text-neutral-500 mt-2">No hay templates activos. Crea uno en /templates.</p>
          )}
        </div>
      )}

      {noteOpen && (
        <div className="w-full mt-3 p-3 border border-neutral-200 rounded-md bg-neutral-50">
          <textarea
            value={noteBody}
            onChange={e => setNoteBody(e.target.value)}
            placeholder="Escribe una nota..."
            rows={3}
            className="w-full px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white"
          />
          <div className="flex justify-end gap-2 mt-2">
            <button onClick={() => setNoteOpen(false)} className="px-3 py-1.5 text-sm text-neutral-600">Cancelar</button>
            <button onClick={saveNote} disabled={!noteBody.trim() || pending} className="px-3 py-1.5 bg-brand-600 text-white text-sm rounded-md disabled:opacity-50">Guardar</button>
          </div>
        </div>
      )}
    </div>
  );
}

// helper para sacar workspace_id del usuario actual
async function getWsId(supabase: any): Promise<string> {
  const { data } = await supabase.from('crm_users').select('workspace_id').limit(1).single();
  return data?.workspace_id;
}
