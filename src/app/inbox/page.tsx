import { createClient } from '@/lib/supabase/server';
import { SegmentBadge } from '@/components/SegmentBadge';
import { relativeTime } from '@/lib/utils';
import { cn } from '@/lib/utils';
import Link from 'next/link';
import { MessageCircle } from 'lucide-react';
import { Conversation } from './Conversation';

export const dynamic = 'force-dynamic';

type Thread = {
  lead_id: string;
  full_name: string | null;
  phone: string | null;
  email: string | null;
  marketing_segment: string | null;
  pipeline_stage: string | null;
  engagement_score: number | null;
  agent_paused: boolean;
  last_inbound_at: string;
  last_inbound_text: string | null;
  last_inbound_channel: string;
  last_outbound_at: string | null;
  unread: boolean;
};

export default async function InboxPage({
  searchParams
}: {
  searchParams: Promise<{ lead?: string }>;
}) {
  const { lead: selectedId } = await searchParams;
  const supabase = await createClient();

  const { data: threads } = await supabase.rpc('inbox_threads', { p_limit: 100 });
  const list: Thread[] = threads ?? [];

  const selected = list.find(t => t.lead_id === selectedId) ?? list[0] ?? null;

  const { data: messages } = selected
    ? await supabase.rpc('conversation_messages', { p_lead_id: selected.lead_id })
    : { data: [] };

  return (
    <div className="flex h-screen overflow-hidden">
      {/* Lista de threads */}
      <div className="w-80 shrink-0 border-r border-neutral-200 bg-white flex flex-col">
        <div className="px-4 py-4 border-b border-neutral-100">
          <h1 className="font-semibold text-neutral-900 flex items-center gap-2">
            <MessageCircle size={18} /> Inbox
          </h1>
          <p className="text-xs text-neutral-500 mt-0.5">
            {list.filter(t => t.unread).length} sin leer · {list.length} conversaciones
          </p>
        </div>
        <div className="flex-1 overflow-y-auto">
          {list.length === 0 && (
            <p className="p-4 text-sm text-neutral-500">
              Aún no hay conversaciones. Cuando un lead responda por WhatsApp o email, aparece aquí.
            </p>
          )}
          {list.map(t => (
            <Link
              key={t.lead_id}
              href={`/inbox?lead=${t.lead_id}`}
              className={cn(
                'block px-4 py-3 border-b border-neutral-100 hover:bg-neutral-50 transition-colors',
                selected?.lead_id === t.lead_id && 'bg-brand-50 hover:bg-brand-50'
              )}
            >
              <div className="flex items-center justify-between gap-2">
                <span className={cn('text-sm truncate', t.unread ? 'font-semibold text-neutral-900' : 'text-neutral-700')}>
                  {t.full_name ?? t.phone ?? t.email ?? 'Sin nombre'}
                </span>
                <span className="text-[11px] text-neutral-400 shrink-0">{relativeTime(t.last_inbound_at)}</span>
              </div>
              <div className="flex items-center gap-1.5 mt-1">
                {t.unread && <span className="w-2 h-2 rounded-full bg-brand-600 shrink-0" />}
                <p className={cn('text-xs truncate', t.unread ? 'text-neutral-800' : 'text-neutral-500')}>
                  {t.last_inbound_text ?? '—'}
                </p>
              </div>
              <div className="flex items-center gap-1.5 mt-1.5">
                <SegmentBadge segment={t.marketing_segment} />
                {t.agent_paused && (
                  <span className="text-[10px] px-1.5 py-0.5 rounded bg-amber-100 text-amber-800 font-medium">
                    agente en pausa
                  </span>
                )}
              </div>
            </Link>
          ))}
        </div>
      </div>

      {/* Conversación */}
      {selected ? (
        <Conversation
          key={selected.lead_id}
          lead={{
            id: selected.lead_id,
            full_name: selected.full_name,
            phone: selected.phone,
            email: selected.email,
            marketing_segment: selected.marketing_segment,
            pipeline_stage: selected.pipeline_stage,
            agent_paused: selected.agent_paused,
            unread: selected.unread
          }}
          messages={messages ?? []}
        />
      ) : (
        <div className="flex-1 flex items-center justify-center text-neutral-400 text-sm">
          Selecciona una conversación
        </div>
      )}
    </div>
  );
}
