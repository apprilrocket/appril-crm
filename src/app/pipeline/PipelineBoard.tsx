'use client';

import { useState, useTransition } from 'react';
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  TouchSensor,
  useSensor,
  useSensors,
  useDroppable,
  useDraggable,
  type DragStartEvent,
  type DragEndEvent,
} from '@dnd-kit/core';
import { CSS } from '@dnd-kit/utilities';
import Link from 'next/link';
import { Phone, Mail, Megaphone, MessageSquare } from 'lucide-react';
import { updateLeadStage } from './actions';
import { relativeTime } from '@/lib/utils';

type Stage = { key: string; label: string; color: string | null; position: number };
export type BoardLead = {
  id: string;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  marketing_segment: string | null;
  pagando_hoy: boolean | null;
  engagement_score: number | null;
  last_engaged_at: string | null;
  last_sent: { value: string | null; at: string } | null;
  last_reply: { value: string | null; at: string } | null;
  action: { text: string; tone: 'urgent' | 'hot' | 'todo' | 'info' } | null;
};
type Lead = BoardLead;
type StageData = { stage: Stage; leads: Lead[]; total: number };

const segmentColors: Record<string, string> = {
  SUPER_HOT: 'bg-red-100 text-red-700',
  HOT:       'bg-orange-100 text-orange-700',
  WARM:      'bg-yellow-100 text-yellow-700',
  COLD:      'bg-sky-100 text-sky-700',
  DO_NOT_EMAIL: 'bg-neutral-100 text-neutral-500',
};

export function PipelineBoard({ initialData }: { initialData: StageData[] }) {
  const [data, setData] = useState(initialData);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 8 } }),
    useSensor(TouchSensor,   { activationConstraint: { delay: 200, tolerance: 8 } })
  );

  // Busca el lead activo en todos los stages
  const activeLead = activeId
    ? data.flatMap(d => d.leads).find(l => l.id === activeId) ?? null
    : null;

  function findStageOfLead(leadId: string): string | null {
    for (const d of data) {
      if (d.leads.some(l => l.id === leadId)) return d.stage.key;
    }
    return null;
  }

  function handleDragStart(event: DragStartEvent) {
    setActiveId(String(event.active.id));
  }

  function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event;
    setActiveId(null);

    if (!over) return;

    const leadId   = String(active.id);
    const newStage = String(over.id);
    const oldStage = findStageOfLead(leadId);

    if (!oldStage || oldStage === newStage) return;

    // Actualización optimista — mueve el lead en el estado local inmediatamente
    setData(prev => {
      const lead = prev.find(d => d.stage.key === oldStage)?.leads.find(l => l.id === leadId);
      if (!lead) return prev;

      return prev.map(d => {
        if (d.stage.key === oldStage) {
          return { ...d, leads: d.leads.filter(l => l.id !== leadId), total: d.total - 1 };
        }
        if (d.stage.key === newStage) {
          return { ...d, leads: [lead, ...d.leads], total: d.total + 1 };
        }
        return d;
      });
    });

    // Persiste en la DB
    startTransition(async () => {
      const result = await updateLeadStage(leadId, newStage);
      if ('error' in result) {
        // Revierte si falla
        setData(initialData);
        console.error('Error al mover lead:', result.error);
      }
    });
  }

  return (
    <DndContext sensors={sensors} onDragStart={handleDragStart} onDragEnd={handleDragEnd}>
      <div className="flex gap-3 overflow-x-auto pb-6 pt-1">
        {data.map(({ stage, leads, total }) => (
          <Column key={stage.key} stage={stage} leads={leads} total={total} />
        ))}
      </div>

      {/* Card flotante mientras se arrastra */}
      <DragOverlay dropAnimation={{ duration: 150, easing: 'ease' }}>
        {activeLead ? <LeadCard lead={activeLead} isDragging /> : null}
      </DragOverlay>

      {isPending && (
        <div className="fixed bottom-4 right-4 bg-neutral-800 text-white text-xs px-3 py-1.5 rounded-full shadow-lg">
          Guardando…
        </div>
      )}
    </DndContext>
  );
}

// ─── Columna droppable ──────────────────────────────────────
function Column({ stage, leads, total }: { stage: Stage; leads: Lead[]; total: number }) {
  const { setNodeRef, isOver } = useDroppable({ id: stage.key });

  return (
    <div
      ref={setNodeRef}
      className={`w-72 shrink-0 rounded-lg transition-colors ${
        isOver ? 'bg-brand-50 ring-2 ring-brand-300' : 'bg-neutral-100'
      }`}
    >
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-2.5">
        <div className="flex items-center gap-2">
          <span
            className="w-2.5 h-2.5 rounded-full shrink-0"
            style={{ backgroundColor: stage.color ?? '#94a3b8' }}
          />
          <span className="text-sm font-medium text-neutral-900">{stage.label}</span>
        </div>
        <span className="text-xs text-neutral-500 tabular-nums">{total.toLocaleString('es-CO')}</span>
      </div>

      {/* Cards */}
      <div className="px-2 pb-3 space-y-2 min-h-[120px]">
        {leads.map(lead => (
          <DraggableCard key={lead.id} lead={lead} />
        ))}
        {leads.length === 0 && (
          <div className={`h-20 rounded-md border-2 border-dashed flex items-center justify-center text-xs transition-colors ${
            isOver ? 'border-brand-300 text-brand-500' : 'border-neutral-200 text-neutral-400'
          }`}>
            Suelta aquí
          </div>
        )}
        {total > leads.length && (
          <Link
            href={`/leads?stage=${stage.key}`}
            className="block text-center text-xs text-brand-600 hover:underline py-1.5"
          >
            Ver los {total.toLocaleString('es-CO')} →
          </Link>
        )}
      </div>
    </div>
  );
}

// ─── Card draggable ─────────────────────────────────────────
function DraggableCard({ lead }: { lead: Lead }) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: lead.id });

  const style = transform
    ? { transform: CSS.Translate.toString(transform), opacity: isDragging ? 0.4 : 1 }
    : undefined;

  return (
    <div ref={setNodeRef} style={style} {...attributes} {...listeners}>
      <LeadCard lead={lead} />
    </div>
  );
}

// ─── Card visual ─────────────────────────────────────────────
const actionTones: Record<string, string> = {
  urgent: 'bg-red-50 text-red-700 border-red-200',
  hot:    'bg-orange-50 text-orange-700 border-orange-200',
  todo:   'bg-amber-50 text-amber-800 border-amber-200',
  info:   'bg-neutral-50 text-neutral-600 border-neutral-200',
};

function LeadCard({ lead, isDragging = false }: { lead: Lead; isDragging?: boolean }) {
  const seg = lead.marketing_segment ?? '';
  const score = lead.engagement_score ?? 0;
  const warming = score > 0 && lead.last_engaged_at &&
    Date.now() - new Date(lead.last_engaged_at).getTime() < 14 * 24 * 60 * 60 * 1000;

  return (
    <Link
      href={`/leads/${lead.id}`}
      onClick={e => { if (isDragging) e.preventDefault(); }}
      className={`block bg-white border rounded-md p-2.5 select-none transition-shadow ${
        isDragging
          ? 'border-brand-300 shadow-lg rotate-1 cursor-grabbing'
          : 'border-neutral-200 hover:border-neutral-300 cursor-grab active:cursor-grabbing'
      }`}
      draggable={false}
    >
      <div className="flex items-start justify-between gap-1">
        <div className="text-sm font-medium text-neutral-900 truncate">
          {lead.full_name ?? <span className="text-neutral-400 italic">sin nombre</span>}
        </div>
        {score > 0 && (
          <span className={`text-[11px] font-semibold shrink-0 ${warming ? 'text-orange-600' : 'text-neutral-400'}`}>
            {warming ? '🔥' : ''}{score}
          </span>
        )}
      </div>

      {/* Contacto */}
      <div className="mt-1 space-y-0.5">
        {lead.email && (
          <div className="flex items-center gap-1 text-[11px] text-neutral-500 truncate">
            <Mail size={10} className="shrink-0" /> {lead.email}
          </div>
        )}
        {lead.phone && (
          <div className="flex items-center gap-1 text-[11px] text-neutral-500 truncate">
            <Phone size={10} className="shrink-0" /> {lead.phone}
          </div>
        )}
        {!lead.email && !lead.phone && <div className="text-[11px] text-neutral-300">sin datos de contacto</div>}
      </div>

      {/* Última campaña / última respuesta */}
      {(lead.last_sent || lead.last_reply) && (
        <div className="mt-1.5 pt-1.5 border-t border-neutral-100 space-y-0.5">
          {lead.last_sent && (
            <div className="flex items-center gap-1 text-[11px] text-neutral-500 truncate">
              <Megaphone size={10} className="shrink-0 text-neutral-400" />
              <span className="truncate">{lead.last_sent.value ?? 'envío'}</span>
              <span className="text-neutral-400 shrink-0">· {relativeTime(lead.last_sent.at)}</span>
            </div>
          )}
          {lead.last_reply && (
            <div className="flex items-center gap-1 text-[11px] text-emerald-700 truncate">
              <MessageSquare size={10} className="shrink-0" />
              <span className="truncate">
                {lead.last_reply.value ? `"${lead.last_reply.value}"` : 'respondió'}
              </span>
              <span className="text-neutral-400 shrink-0">· {relativeTime(lead.last_reply.at)}</span>
            </div>
          )}
        </div>
      )}

      {/* Recomendación accionable */}
      {lead.action && (
        <div className={`mt-1.5 text-[11px] font-medium border rounded px-1.5 py-1 ${actionTones[lead.action.tone]}`}>
          {lead.action.text}
        </div>
      )}

      <div className="flex items-center justify-between mt-1.5">
        {seg && (
          <span className={`text-xs px-1.5 py-0.5 rounded-full font-medium ${segmentColors[seg] ?? 'bg-neutral-100 text-neutral-600'}`}>
            {seg}
          </span>
        )}
        {lead.pagando_hoy && (
          <span className="text-xs text-emerald-600 font-medium ml-auto">$ activo</span>
        )}
      </div>
    </Link>
  );
}
