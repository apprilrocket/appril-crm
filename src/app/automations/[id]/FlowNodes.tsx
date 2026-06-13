'use client';

import { Handle, Position, type NodeProps } from '@xyflow/react';
import { Zap, Mail, MessageCircle, Clock, GitBranch, Trophy, LogOut } from 'lucide-react';

// Tarjeta base de todos los nodos del flujo
function Card({ selected, accent, icon, title, subtitle, children }: {
  selected?: boolean;
  accent: string;
  icon: React.ReactNode;
  title: string;
  subtitle?: string;
  children?: React.ReactNode;
}) {
  return (
    <div
      className={`min-w-[170px] max-w-[220px] rounded-lg border-2 bg-white shadow-sm px-3 py-2.5 ${
        selected ? 'border-brand-500 shadow-md' : 'border-neutral-200'
      }`}
    >
      <div className="flex items-center gap-2">
        <div className={`w-7 h-7 rounded-md flex items-center justify-center shrink-0 ${accent}`}>
          {icon}
        </div>
        <div className="min-w-0">
          <div className="text-xs font-semibold text-neutral-900 truncate">{title}</div>
          {subtitle && <div className="text-[10px] text-neutral-500 truncate">{subtitle}</div>}
        </div>
      </div>
      {children}
    </div>
  );
}

const TRIGGER_LABELS: Record<string, string> = {
  manual: 'Inscripción manual',
  segment_match: 'Por segmento',
  event: 'Por evento',
  stage: 'Por etapa'
};

export function TriggerNode({ data, selected }: NodeProps) {
  const d = data as Record<string, any>;
  const detail =
    d.triggerType === 'event' ? d.eventType :
    d.triggerType === 'stage' ? d.stage :
    d.triggerType === 'segment_match' ? d.segment : undefined;
  return (
    <Card
      selected={selected}
      accent="bg-brand-100 text-brand-700"
      icon={<Zap size={14} />}
      title="Disparador"
      subtitle={`${TRIGGER_LABELS[d.triggerType ?? 'manual']}${detail ? ` · ${detail}` : ''}`}
    >
      <Handle type="source" position={Position.Bottom} className="!bg-brand-500 !w-2.5 !h-2.5" />
    </Card>
  );
}

export function EmailNode({ data, selected }: NodeProps) {
  const d = data as Record<string, any>;
  return (
    <Card
      selected={selected}
      accent="bg-sky-100 text-sky-700"
      icon={<Mail size={14} />}
      title="Enviar email"
      subtitle={d.templateKey ?? '⚠ sin template'}
    >
      <Handle type="target" position={Position.Top} className="!bg-neutral-400 !w-2.5 !h-2.5" />
      <Handle type="source" position={Position.Bottom} className="!bg-sky-500 !w-2.5 !h-2.5" />
    </Card>
  );
}

export function WhatsappNode({ data, selected }: NodeProps) {
  const d = data as Record<string, any>;
  return (
    <Card
      selected={selected}
      accent="bg-emerald-100 text-emerald-700"
      icon={<MessageCircle size={14} />}
      title="Enviar WhatsApp"
      subtitle={d.templateKey ?? '⚠ sin template'}
    >
      <Handle type="target" position={Position.Top} className="!bg-neutral-400 !w-2.5 !h-2.5" />
      <Handle type="source" position={Position.Bottom} className="!bg-emerald-500 !w-2.5 !h-2.5" />
    </Card>
  );
}

const UNIT_LABELS: Record<string, string> = { minutes: 'min', hours: 'h', days: 'días' };

export function WaitNode({ data, selected }: NodeProps) {
  const d = data as Record<string, any>;
  return (
    <Card
      selected={selected}
      accent="bg-amber-100 text-amber-700"
      icon={<Clock size={14} />}
      title="Esperar"
      subtitle={`${d.amount ?? 1} ${UNIT_LABELS[d.unit ?? 'days'] ?? d.unit}`}
    >
      <Handle type="target" position={Position.Top} className="!bg-neutral-400 !w-2.5 !h-2.5" />
      <Handle type="source" position={Position.Bottom} className="!bg-amber-500 !w-2.5 !h-2.5" />
    </Card>
  );
}

const KIND_LABELS: Record<string, string> = {
  email_opened: 'Abrió email',
  email_clicked: 'Click en email',
  wa_replied: 'Respondió WA',
  any_reply: 'Respondió algo',
  stage_is: 'Etapa es',
  segment_is: 'Segmento es',
  heat_gte: 'Heat ≥',
  event_occurred: 'Evento'
};

function kindSummary(d: Record<string, any>) {
  const base = KIND_LABELS[d.kind] ?? d.kind ?? '⚠ sin criterio';
  return d.value ? `${base} ${d.value}` : base;
}

export function ConditionNode({ data, selected }: NodeProps) {
  const d = data as Record<string, any>;
  return (
    <Card
      selected={selected}
      accent="bg-violet-100 text-violet-700"
      icon={<GitBranch size={14} />}
      title="Condición"
      subtitle={kindSummary(d)}
    >
      <Handle type="target" position={Position.Top} className="!bg-neutral-400 !w-2.5 !h-2.5" />
      <div className="flex justify-between mt-2 px-1 text-[10px] font-semibold">
        <span className="text-emerald-700">Sí</span>
        <span className="text-red-600">No</span>
      </div>
      <Handle id="yes" type="source" position={Position.Bottom} style={{ left: '25%' }} className="!bg-emerald-500 !w-2.5 !h-2.5" />
      <Handle id="no" type="source" position={Position.Bottom} style={{ left: '75%' }} className="!bg-red-400 !w-2.5 !h-2.5" />
    </Card>
  );
}

export function GoalNode({ data, selected }: NodeProps) {
  const d = data as Record<string, any>;
  return (
    <Card
      selected={selected}
      accent="bg-yellow-100 text-yellow-700"
      icon={<Trophy size={14} />}
      title="Meta 🏆"
      subtitle={`${kindSummary(d)} · plazo ${d.timeoutDays ?? 30}d`}
    >
      <Handle type="target" position={Position.Top} className="!bg-neutral-400 !w-2.5 !h-2.5" />
      <div className="flex justify-end mt-2 px-1 text-[10px] font-semibold">
        <span className="text-red-600">No (plazo vencido)</span>
      </div>
      <Handle id="no" type="source" position={Position.Bottom} style={{ left: '75%' }} className="!bg-red-400 !w-2.5 !h-2.5" />
    </Card>
  );
}

export function ExitNode({ selected }: NodeProps) {
  return (
    <Card
      selected={selected}
      accent="bg-neutral-200 text-neutral-600"
      icon={<LogOut size={14} />}
      title="Salida"
      subtitle="Fin del flujo"
    >
      <Handle type="target" position={Position.Top} className="!bg-neutral-400 !w-2.5 !h-2.5" />
    </Card>
  );
}
