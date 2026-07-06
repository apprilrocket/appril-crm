'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import { createClient } from '@/lib/supabase/client';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { cn } from '@/lib/utils';
import { SegmentBadge } from '@/components/SegmentBadge';
import { eventMeta } from '@/lib/events';
import { Send, Bot, User, Mail, ExternalLink, RefreshCw, MousePointerClick } from 'lucide-react';

// Linkify seguro (sin dangerouslySetInnerHTML): parte el texto por URLs y
// renderiza los segmentos http(s) como <a>. Preserva whitespace-pre-wrap
// porque el texto entre links se emite tal cual.
const URL_RE = /(https?:\/\/[^\s]+)/g;
function linkify(text: string) {
  if (!text) return text;
  const parts = text.split(URL_RE);
  return parts.map((part, i) => {
    if (i % 2 === 1) {
      // Quitar puntuación de cierre común pegada al final de la URL.
      const m = part.match(/^(.*?)([.,;:!?)\]]*)$/s);
      const url = m ? m[1] : part;
      const trail = m ? m[2] : '';
      return (
        <span key={i}>
          <a
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            className="underline break-all"
          >
            {url}
          </a>
          {trail}
        </span>
      );
    }
    return <span key={i}>{part}</span>;
  });
}

type Lead = {
  id: string;
  full_name: string | null;
  phone: string | null;
  email: string | null;
  marketing_segment: string | null;
  pipeline_stage: string | null;
  agent_paused: boolean;
  unread: boolean;
  last_wa_reply_at: string | null;
  can_whatsapp: boolean | null;
  can_email: boolean | null;
};

const WA_WINDOW_MS = 24 * 60 * 60 * 1000;

function formatLeft(ms: number): string {
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  return h > 0 ? `${h} h ${m} min` : `${m} min`;
}

type Message = {
  id: string;
  direction: 'in' | 'out' | 'system';
  via: string; // 'lead' | 'agent' | 'manual' | 'campaign' | 'automation' | 'queue' | event_type (system)
  channel: string;
  body: string;
  status: string;
  happened_at: string;
  buttons?: string[] | null;
  kind?: 'message' | 'system';
  is_button_reply?: boolean;
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
  const [error, setError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  // Ventana de servicio de 24h de Meta: el texto libre por WhatsApp solo es
  // válido dentro de las 24h desde el último mensaje ENTRANTE del lead (rodante).
  // `now` arranca en 0 (determinista en SSR y en la primera hidratación → sin
  // hydration mismatch); el reloj real se establece tras montar, en cliente, y se
  // refresca cada 30s para que el candado se cierre solo. El backend (inbox-send)
  // valida otra vez antes de enviar (doble candado).
  const [now, setNow] = useState(0);
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    setMounted(true);
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(t);
  }, []);

  const hasWhatsapp = !!lead.phone;
  const hasEmail = !!lead.email;
  const hasAnyChannel = hasWhatsapp || hasEmail;

  const lastWaMs = lead.last_wa_reply_at ? new Date(lead.last_wa_reply_at).getTime() : 0;
  const waWindowMsLeft = lastWaMs > 0 ? WA_WINDOW_MS - (now - lastWaMs) : -1;
  // Hasta montar no evaluamos con reloj real → estado seguro (ventana cerrada),
  // nunca habilitamos texto libre por error en el primer render.
  const waWindowOpen = mounted && waWindowMsLeft > 0;
  const waOptOut = lead.can_whatsapp === false;
  const emailOptOut = lead.can_email === false;

  // Bloqueo del canal activo → deshabilita la caja y explica por qué.
  const waBlock: 'nophone' | 'optout' | 'window' | null =
    !hasWhatsapp ? 'nophone' : waOptOut ? 'optout' : !waWindowOpen ? 'window' : null;
  const emailBlock: 'noemail' | 'optout' | null =
    !hasEmail ? 'noemail' : emailOptOut ? 'optout' : null;

  // Canal por defecto: WhatsApp si hay teléfono, si no email. El gating por canal
  // (mensajes + inputs deshabilitados) se encarga del estado bloqueado; el default
  // no depende del reloj para no arrastrar la ventana al render de servidor.
  const [channel, setChannel] = useState<'whatsapp' | 'email'>(hasWhatsapp ? 'whatsapp' : 'email');

  const currentBlock = channel === 'whatsapp' ? waBlock : emailBlock;
  const canSend = hasAnyChannel && !currentBlock;

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
    if (!text.trim() || !canSend) return;
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
          // Eventos de sistema: chip centrado, discreto (no burbuja izq/der).
          if (m.kind === 'system' || m.direction === 'system') {
            const meta = eventMeta(m.via);
            return (
              <div key={m.id} className="flex justify-center my-1">
                <div className="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-neutral-100 border border-neutral-200 text-[11px] text-neutral-600">
                  <span>{meta.icon}</span>
                  <span>{m.body}</span>
                  <span className="text-neutral-400">
                    · {new Date(m.happened_at).toLocaleString('es-CO', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                  </span>
                </div>
              </div>
            );
          }

          const isIn = m.direction === 'in';
          const isAgent = m.via === 'agent';
          const isButtonReply = isIn && m.is_button_reply === true;
          return (
            <div key={m.id} className={cn('flex', isIn ? 'justify-start' : 'justify-end')}>
              <div
                className={cn(
                  'max-w-[70%] rounded-2xl px-4 py-2.5 text-sm whitespace-pre-wrap break-words',
                  isButtonReply
                    ? 'bg-white border border-dashed border-emerald-300 text-neutral-900 rounded-bl-sm'
                    : isIn
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
                {isButtonReply ? (
                  <div className="inline-flex items-center gap-1.5">
                    <MousePointerClick size={13} className="text-emerald-600 shrink-0" />
                    <span>
                      <span className="text-[11px] text-emerald-700 font-medium">tocó el botón: </span>
                      «{m.body}»
                    </span>
                  </div>
                ) : (
                  linkify(m.body)
                )}
                {/* Botones ofrecidos por el agente: pills no interactivas bajo el texto */}
                {!isIn && m.buttons && m.buttons.length > 0 && (
                  <div className="flex flex-wrap gap-1.5 mt-2">
                    {m.buttons.map((b, i) => (
                      <span
                        key={i}
                        className={cn(
                          'px-2 py-0.5 text-[11px] rounded-full border',
                          isAgent || m.via === 'manual'
                            ? 'border-white/40 text-white/90'
                            : 'border-neutral-400 text-neutral-700'
                        )}
                      >
                        {b}
                      </span>
                    ))}
                  </div>
                )}
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
        {!hasAnyChannel && (
          <p className="text-[11px] text-red-600 mb-2">
            Este lead no tiene canal de contacto (ni teléfono ni email). Agrégalo en{' '}
            <Link href={`/leads/${lead.id}`} className="underline font-medium hover:text-red-800">
              el perfil del lead →
            </Link>
          </p>
        )}
        {!lead.agent_paused && channel === 'whatsapp' && hasWhatsapp && (
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
                disabled={!canSend}
                className="w-full px-3 py-2 text-sm border border-neutral-200 rounded-md disabled:bg-neutral-50 disabled:text-neutral-400"
              />
            )}
            <textarea
              value={text}
              onChange={e => setText(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) send();
              }}
              placeholder={
                currentBlock
                  ? 'Canal no disponible para este lead'
                  : channel === 'whatsapp' ? 'Responder por WhatsApp… (⌘↵ para enviar)' : 'Responder por email… (⌘↵ para enviar)'
              }
              rows={2}
              disabled={!canSend}
              className="w-full px-3 py-2 text-sm border border-neutral-200 rounded-md resize-none disabled:bg-neutral-50 disabled:text-neutral-400"
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
              disabled={pending || !text.trim() || !canSend}
              className="inline-flex items-center justify-center gap-1.5 px-4 py-2 text-sm bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white rounded-md"
            >
              <Send size={14} /> Enviar
            </button>
          </div>
        </div>

        {/* WhatsApp: fuera de la ventana de 24h → solo templates, con enlace al lead */}
        {channel === 'whatsapp' && waBlock === 'window' && (
          <p className="text-[11px] text-amber-700 mt-2">
            Estás fuera de la ventana de envío libre de mensajes (24h de Meta). Solo puedes enviar templates a este lead.{' '}
            <Link href={`/leads/${lead.id}`} className="underline font-medium hover:text-amber-900">
              Enviar template →
            </Link>
          </p>
        )}
        {channel === 'whatsapp' && waBlock === 'optout' && (
          <p className="text-[11px] text-red-600 mt-2">
            Este lead no puede recibir WhatsApp (opt-out o número sin WhatsApp).
          </p>
        )}
        {channel === 'whatsapp' && !waBlock && (
          <p className="text-[11px] text-neutral-400 mt-2">
            Ventana de Meta abierta · quedan {formatLeft(waWindowMsLeft)} para texto libre.
          </p>
        )}
        {channel === 'email' && emailBlock === 'optout' && (
          <p className="text-[11px] text-red-600 mt-2">
            Este lead no puede recibir email (rebote o baja).
          </p>
        )}
        {error && <p className="text-sm text-red-600 mt-2">Error: {error}</p>}
      </div>
    </div>
  );
}
