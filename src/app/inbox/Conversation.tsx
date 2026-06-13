'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import { createClient } from '@/lib/supabase/client';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { cn } from '@/lib/utils';
import { SegmentBadge } from '@/components/SegmentBadge';
import { Send, Bot, User, Mail, ExternalLink, RefreshCw } from 'lucide-react';

type Lead = {
  id: string;
  full_name: string | null;
  phone: string | null;
  email: string | null;
  marketing_segment: string | null;
  pipeline_stage: string | null;
  agent_paused: boolean;
  unread: boolean;
};

type Message = {
  id: string;
  direction: 'in' | 'out';
  via: string; // 'lead' | 'agent' | 'manual' | 'campaign' | 'automation' | 'queue'
  channel: string;
  body: string;
  status: string;
  happened_at: string;
};

const VIA_LABEL: Record<string, string> = {
  agent: 'Agente IA',
  manual: 'Tú',
  campaign: 'Campaña',
  automation: 'Automatización',
  queue: 'Sistema'
};

export function Conversation({ lead, messages }: { lead: Lead; messages: Message[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [refreshing, startRefresh] = useTransition();
  const [text, setText] = useState('');
  const [subject, setSubject] = useState('');
  const [channel, setChannel] = useState<'whatsapp' | 'email'>(lead.phone ? 'whatsapp' : 'email');
  const [error, setError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  // Marcar leído al abrir la conversación
  useEffect(() => {
    if (!lead.unread) return;
    const supabase = createClient();
    supabase
      .from('leads_master')
      .update({ inbox_read_at: new Date().toISOString() })
      .eq('id', lead.id)
      .then(() => router.refresh());
  }, [lead.id, lead.unread, router]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView();
  }, [messages.length]);

  // Auto-refresh cada 5s mientras la pestaña está visible — los mensajes nuevos
  // (del lead o del agente IA) aparecen sin recargar la página.
  useEffect(() => {
    const interval = setInterval(() => {
      if (document.visibilityState === 'visible') {
        startRefresh(() => router.refresh());
      }
    }, 5000);
    return () => clearInterval(interval);
  }, [router]);

  async function toggleAgent() {
    startTransition(async () => {
      const supabase = createClient();
      await supabase.from('leads_master').update({ agent_paused: !lead.agent_paused }).eq('id', lead.id);
      router.refresh();
    });
  }

  async function send() {
    if (!text.trim()) return;
    setError(null);
    startTransition(async () => {
      const supabase = createClient();
      const { data, error: fnError } = await supabase.functions.invoke('inbox-send', {
        body: { lead_id: lead.id, channel, text, subject: channel === 'email' ? subject : undefined }
      });
      if (fnError) {
        // FunctionsHttpError: el body trae el detalle
        let detail = fnError.message;
        try {
          const ctx = await (fnError as any).context?.json?.();
          if (ctx?.error) detail = ctx.error;
        } catch { /* sin detalle */ }
        setError(detail);
        return;
      }
      if (data && !data.ok) { setError(data.error ?? 'Error desconocido'); return; }
      setText('');
      setSubject('');
      router.refresh();
    });
  }

  return (
    <div className="flex-1 flex flex-col min-w-0 bg-neutral-50">
      {/* Header */}
      <div className="px-5 py-3 bg-white border-b border-neutral-200 flex items-center gap-3">
        <div className="min-w-0">
          <Link href={`/leads/${lead.id}`} className="font-semibold text-neutral-900 hover:text-brand-700 inline-flex items-center gap-1.5">
            {lead.full_name ?? lead.phone ?? lead.email ?? 'Sin nombre'}
            <ExternalLink size={13} className="text-neutral-400" />
          </Link>
          <div className="flex items-center gap-2 text-xs text-neutral-500 mt-0.5">
            {lead.phone && <span>{lead.phone}</span>}
            {lead.email && <span className="truncate">{lead.email}</span>}
            <SegmentBadge segment={lead.marketing_segment} />
          </div>
        </div>

        {/* Recargar */}
        <button
          onClick={() => startRefresh(() => router.refresh())}
          disabled={refreshing}
          title="Recargar conversación"
          className="ml-auto p-2 text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100 rounded-md transition-colors"
        >
          <RefreshCw size={15} className={refreshing ? 'animate-spin' : ''} />
        </button>

        {/* Toggle agente IA */}
        <button
          onClick={toggleAgent}
          disabled={pending}
          title={lead.agent_paused
            ? 'El agente IA NO responde a este lead. Click para reactivarlo.'
            : 'El agente IA responde automáticamente. Click para pausarlo y tomar la conversación.'}
          className={cn(
            'inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-full border transition-colors',
            lead.agent_paused
              ? 'bg-amber-50 border-amber-300 text-amber-800 hover:bg-amber-100'
              : 'bg-emerald-50 border-emerald-300 text-emerald-800 hover:bg-emerald-100'
          )}
        >
          <Bot size={14} />
          {lead.agent_paused ? 'Agente en pausa — respondes tú' : 'Agente IA activo'}
        </button>
      </div>

      {/* Mensajes */}
      <div className="flex-1 overflow-y-auto px-5 py-4 space-y-2">
        {messages.map(m => {
          const isIn = m.direction === 'in';
          const isAgent = m.via === 'agent';
          return (
            <div key={m.id} className={cn('flex', isIn ? 'justify-start' : 'justify-end')}>
              <div
                className={cn(
                  'max-w-[70%] rounded-2xl px-4 py-2.5 text-sm whitespace-pre-wrap break-words',
                  isIn
                    ? 'bg-white border border-neutral-200 text-neutral-900 rounded-bl-sm'
                    : isAgent
                      ? 'bg-violet-600 text-white rounded-br-sm'
                      : m.via === 'manual'
                        ? 'bg-brand-600 text-white rounded-br-sm'
                        : 'bg-neutral-200 text-neutral-800 rounded-br-sm'
                )}
              >
                {!isIn && (
                  <div className={cn('text-[10px] font-medium mb-0.5 flex items-center gap-1', isAgent || m.via === 'manual' ? 'opacity-75' : 'text-neutral-500')}>
                    {isAgent ? <Bot size={11} /> : <User size={11} />}
                    {VIA_LABEL[m.via] ?? m.via}
                    {m.channel === 'email' && <Mail size={11} />}
                    {m.status === 'failed' && <span className="text-red-200">· falló</span>}
                    {m.status === 'pending' && <span>· en cola</span>}
                  </div>
                )}
                {m.body}
                <div className={cn('text-[10px] mt-1', isIn ? 'text-neutral-400' : 'opacity-60')}>
                  {new Date(m.happened_at).toLocaleString('es-CO', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                </div>
              </div>
            </div>
          );
        })}
        <div ref={bottomRef} />
      </div>

      {/* Caja de respuesta */}
      <div className="bg-white border-t border-neutral-200 p-4">
        {!lead.agent_paused && channel === 'whatsapp' && (
          <p className="text-[11px] text-amber-700 mb-2">
            El agente IA está activo: también responderá a los próximos mensajes del lead. Pásalo a pausa si vas a llevar tú la conversación.
          </p>
        )}
        <div className="flex items-start gap-2">
          <div className="flex-1 space-y-2">
            {channel === 'email' && (
              <input
                value={subject}
                onChange={e => setSubject(e.target.value)}
                placeholder="Asunto"
                className="w-full px-3 py-2 text-sm border border-neutral-200 rounded-md"
              />
            )}
            <textarea
              value={text}
              onChange={e => setText(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) send();
              }}
              placeholder={channel === 'whatsapp' ? 'Responder por WhatsApp… (⌘↵ para enviar)' : 'Responder por email… (⌘↵ para enviar)'}
              rows={2}
              className="w-full px-3 py-2 text-sm border border-neutral-200 rounded-md resize-none"
            />
          </div>
          <div className="flex flex-col gap-2">
            <select
              value={channel}
              onChange={e => setChannel(e.target.value as 'whatsapp' | 'email')}
              className="px-2 py-2 text-xs border border-neutral-200 rounded-md bg-white"
            >
              {lead.phone && <option value="whatsapp">WhatsApp</option>}
              {lead.email && <option value="email">Email</option>}
            </select>
            <button
              onClick={send}
              disabled={pending || !text.trim()}
              className="inline-flex items-center justify-center gap-1.5 px-4 py-2 text-sm bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white rounded-md"
            >
              <Send size={14} /> Enviar
            </button>
          </div>
        </div>
        {channel === 'whatsapp' && (
          <p className="text-[11px] text-neutral-400 mt-2">
            Texto libre: válido dentro de las 24h desde el último mensaje del lead (ventana de Meta). Fuera de la ventana usa un template desde el perfil del lead.
          </p>
        )}
        {error && <p className="text-sm text-red-600 mt-2">Error: {error}</p>}
      </div>
    </div>
  );
}
