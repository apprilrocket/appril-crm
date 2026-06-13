'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { SegmentBadge, StageBadge, HeatBadge } from '@/components/SegmentBadge';
import { relativeTime, cn } from '@/lib/utils';
import { SEGMENTS, type LeadsFilter } from '@/lib/leadFilters';
import { bulkUpdateLeads, bulkDeleteLeads, type BulkPatch } from './actions';

export type LeadRow = {
  id: string;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  marketing_segment: string | null;
  pipeline_stage: string | null;
  source: string | null;
  can_email: boolean | null;
  can_whatsapp: boolean | null;
  last_contacted_at: string | null;
  total_citas: number | null;
  engagement_score: number | null;
  last_engaged_at: string | null;
};

type Stage = { key: string; label: string; color: string | null };

const CHANNEL_ACTIONS: [string, string][] = [
  ['email_on',  '✉ Habilitar email'],
  ['email_off', '✉ Deshabilitar email'],
  ['wa_on',     '💬 Habilitar WhatsApp'],
  ['wa_off',    '💬 Deshabilitar WhatsApp'],
];

export function LeadsTable({
  leads,
  stages,
  filter,
  totalCount,
  sortHref,
  sortedByHeat,
}: {
  leads: LeadRow[];
  stages: Stage[];
  filter: LeadsFilter;
  totalCount: number;
  sortHref: string;
  sortedByHeat: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [allMatching, setAllMatching] = useState(false);
  const [feedback, setFeedback] = useState<string | null>(null);

  const [stageValue, setStageValue] = useState('');
  const [segmentValue, setSegmentValue] = useState('');
  const [channelValue, setChannelValue] = useState('');

  const stageMap = new Map(stages.map(s => [s.key, s]));
  const pageIds = leads.map(l => l.id);
  const pageFullySelected = pageIds.length > 0 && pageIds.every(id => selected.has(id));
  const effectiveCount = allMatching ? totalCount : selected.size;

  function toggleOne(id: string) {
    setAllMatching(false);
    setSelected(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function togglePage() {
    setAllMatching(false);
    setSelected(prev => {
      if (pageFullySelected) {
        const next = new Set(prev);
        pageIds.forEach(id => next.delete(id));
        return next;
      }
      return new Set([...prev, ...pageIds]);
    });
  }

  function clearSelection() {
    setSelected(new Set());
    setAllMatching(false);
    setFeedback(null);
  }

  function apply(patch: BulkPatch, label: string) {
    const target = allMatching ? { filter } : { ids: [...selected] };
    const n = effectiveCount;
    if (!confirm(`¿${label} para ${n.toLocaleString('es-CO')} lead${n === 1 ? '' : 's'}?`)) return;
    setFeedback(null);
    startTransition(async () => {
      const res = await bulkUpdateLeads(target, patch);
      if ('error' in res) {
        setFeedback(`Error: ${res.error}`);
      } else {
        setFeedback(`✓ ${res.updated.toLocaleString('es-CO')} leads actualizados`);
        setStageValue(''); setSegmentValue(''); setChannelValue('');
        clearSelectionKeepFeedback();
        router.refresh();
      }
    });
  }

  function clearSelectionKeepFeedback() {
    setSelected(new Set());
    setAllMatching(false);
  }

  function deleteSelected() {
    const target = allMatching ? { filter } : { ids: [...selected] };
    const n = effectiveCount;
    const typed = prompt(
      `⚠️ Vas a ELIMINAR ${n.toLocaleString('es-CO')} lead${n === 1 ? '' : 's'} DEFINITIVAMENTE.\n` +
      `Se borran también sus notas, tareas y mensajes en cola. Esto no se puede deshacer.\n\n` +
      `Para confirmar, escribe el número exacto de leads (${n}):`
    );
    if (typed === null) return;
    if (typed.trim() !== String(n)) {
      setFeedback('Borrado cancelado: el número no coincide.');
      return;
    }
    setFeedback(null);
    startTransition(async () => {
      const res = await bulkDeleteLeads(target);
      if ('error' in res) {
        setFeedback(`Error: ${res.error}`);
      } else {
        setFeedback(`🗑 ${res.deleted.toLocaleString('es-CO')} leads eliminados`);
        clearSelectionKeepFeedback();
        router.refresh();
      }
    });
  }

  function applyChannel(value: string) {
    const patch: BulkPatch =
      value === 'email_on'  ? { can_email: true } :
      value === 'email_off' ? { can_email: false } :
      value === 'wa_on'     ? { can_whatsapp: true } :
                              { can_whatsapp: false };
    apply(patch, CHANNEL_ACTIONS.find(([v]) => v === value)?.[1] ?? 'Cambiar canal');
  }

  return (
    <div className="pb-20">
      <div className="bg-white border border-neutral-200 rounded-lg overflow-hidden">
        {pageFullySelected && totalCount > pageIds.length && !allMatching && (
          <div className="px-3 py-2 bg-brand-50 border-b border-brand-100 text-xs text-neutral-700">
            Seleccionaste los {pageIds.length} de esta página.{' '}
            <button onClick={() => setAllMatching(true)} className="font-medium text-brand-700 hover:underline">
              Seleccionar los {totalCount.toLocaleString('es-CO')} que coinciden con el filtro
            </button>
          </div>
        )}
        {allMatching && (
          <div className="px-3 py-2 bg-brand-50 border-b border-brand-100 text-xs text-neutral-700">
            ✓ Seleccionados <strong>los {totalCount.toLocaleString('es-CO')} leads</strong> que coinciden con el filtro.{' '}
            <button onClick={clearSelection} className="text-brand-700 hover:underline">Deshacer</button>
          </div>
        )}
        <table className="w-full text-sm">
          <thead className="bg-neutral-50 text-xs uppercase text-neutral-500">
            <tr>
              <th className="px-3 py-2 w-8">
                <input
                  type="checkbox"
                  checked={pageFullySelected}
                  onChange={togglePage}
                  className="accent-brand-600 cursor-pointer"
                  title="Seleccionar página"
                />
              </th>
              <Th>Nombre</Th><Th>Contacto</Th><Th>Segmento</Th><Th>Etapa</Th>
              <Th>
                <Link href={sortHref} className="hover:text-neutral-900" title="Ordenar por heat">
                  Heat {sortedByHeat ? '↓' : ''}
                </Link>
              </Th>
              <Th>Canales</Th><Th className="text-right">Citas</Th>
              <Th>Últ. contacto</Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-neutral-100">
            {leads.map(l => {
              const st = stageMap.get(l.pipeline_stage ?? 'new');
              const isSelected = allMatching || selected.has(l.id);
              return (
                <tr key={l.id} className={cn('hover:bg-neutral-50', isSelected && 'bg-brand-50/60')}>
                  <td className="px-3 py-2">
                    <input
                      type="checkbox"
                      checked={isSelected}
                      onChange={() => toggleOne(l.id)}
                      className="accent-brand-600 cursor-pointer"
                    />
                  </td>
                  <td className="px-3 py-2">
                    <Link href={`/leads/${l.id}`} className="text-brand-600 hover:underline font-medium">
                      {l.full_name ?? <span className="text-neutral-400 italic">sin nombre</span>}
                    </Link>
                    <div className="text-xs text-neutral-400">{l.source ?? '—'}</div>
                  </td>
                  <td className="px-3 py-2 text-neutral-700">
                    <div className="text-xs">{l.email ?? '—'}</div>
                    <div className="text-xs text-neutral-500">{l.phone ?? '—'}</div>
                  </td>
                  <td className="px-3 py-2"><SegmentBadge segment={l.marketing_segment} /></td>
                  <td className="px-3 py-2"><StageBadge stage={st?.label ?? l.pipeline_stage ?? 'new'} color={st?.color} /></td>
                  <td className="px-3 py-2">
                    <HeatBadge score={l.engagement_score} lastEngagedAt={l.last_engaged_at} />
                    {l.last_engaged_at && (
                      <div className="text-[10px] text-neutral-400">{relativeTime(l.last_engaged_at)}</div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    <span className={l.can_email ? 'text-emerald-700' : 'text-neutral-300'}>✉</span>
                    <span className={`ml-1 ${l.can_whatsapp ? 'text-emerald-700' : 'text-neutral-300'}`}>WA</span>
                  </td>
                  <td className="px-3 py-2 text-right text-xs text-neutral-700">{l.total_citas ?? 0}</td>
                  <td className="px-3 py-2 text-xs text-neutral-500">
                    {l.last_contacted_at ? new Date(l.last_contacted_at).toLocaleDateString('es-CO') : 'nunca'}
                  </td>
                </tr>
              );
            })}
            {leads.length === 0 && (
              <tr><td colSpan={9} className="text-center py-12 text-neutral-400 text-sm">Sin resultados.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Barra de acciones en lote */}
      {effectiveCount > 0 && (
        <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-40 bg-neutral-900 text-white rounded-xl shadow-xl px-4 py-3 flex flex-wrap items-center gap-3 max-w-[95vw]">
          <span className="text-sm font-medium whitespace-nowrap">
            {effectiveCount.toLocaleString('es-CO')} seleccionado{effectiveCount === 1 ? '' : 's'}
          </span>

          <span className="flex items-center gap-1.5">
            <select
              value={stageValue}
              onChange={e => setStageValue(e.target.value)}
              className="text-xs bg-neutral-800 border border-neutral-700 rounded-md px-2 py-1.5 text-white"
            >
              <option value="">Mover a etapa…</option>
              {stages.map(s => <option key={s.key} value={s.key}>{s.label}</option>)}
            </select>
            {stageValue && (
              <button
                disabled={pending}
                onClick={() => apply({ pipeline_stage: stageValue }, `Mover a "${stageMap.get(stageValue)?.label}"`)}
                className="text-xs bg-brand-600 hover:bg-brand-700 px-2.5 py-1.5 rounded-md disabled:opacity-50"
              >
                Aplicar
              </button>
            )}
          </span>

          <span className="flex items-center gap-1.5">
            <select
              value={segmentValue}
              onChange={e => setSegmentValue(e.target.value)}
              className="text-xs bg-neutral-800 border border-neutral-700 rounded-md px-2 py-1.5 text-white"
            >
              <option value="">Cambiar segmento…</option>
              {SEGMENTS.map(s => <option key={s} value={s}>{s}</option>)}
            </select>
            {segmentValue && (
              <button
                disabled={pending}
                onClick={() => apply({ marketing_segment: segmentValue }, `Cambiar segmento a ${segmentValue}`)}
                className="text-xs bg-brand-600 hover:bg-brand-700 px-2.5 py-1.5 rounded-md disabled:opacity-50"
              >
                Aplicar
              </button>
            )}
          </span>

          <span className="flex items-center gap-1.5">
            <select
              value={channelValue}
              onChange={e => setChannelValue(e.target.value)}
              className="text-xs bg-neutral-800 border border-neutral-700 rounded-md px-2 py-1.5 text-white"
            >
              <option value="">Canales…</option>
              {CHANNEL_ACTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
            {channelValue && (
              <button
                disabled={pending}
                onClick={() => applyChannel(channelValue)}
                className="text-xs bg-brand-600 hover:bg-brand-700 px-2.5 py-1.5 rounded-md disabled:opacity-50"
              >
                Aplicar
              </button>
            )}
          </span>

          <button
            disabled={pending}
            onClick={deleteSelected}
            className="text-xs bg-red-600/20 border border-red-500/50 text-red-300 hover:bg-red-600 hover:text-white px-2.5 py-1.5 rounded-md disabled:opacity-50 transition-colors"
            title="Eliminar definitivamente los leads seleccionados"
          >
            🗑 Eliminar
          </button>

          {pending && <span className="text-xs text-neutral-300">Aplicando…</span>}
          {feedback && <span className="text-xs text-emerald-400">{feedback}</span>}

          <button onClick={clearSelection} className="text-xs text-neutral-400 hover:text-white ml-1">
            ✕ Limpiar
          </button>
        </div>
      )}

      {/* Feedback persistente cuando la barra se cierra tras aplicar */}
      {effectiveCount === 0 && feedback && (
        <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-40 bg-emerald-600 text-white rounded-xl shadow-xl px-4 py-2 text-sm">
          {feedback}
          <button onClick={() => setFeedback(null)} className="ml-3 text-emerald-200 hover:text-white">✕</button>
        </div>
      )}
    </div>
  );
}

function Th({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-3 py-2 text-left font-medium ${className}`}>{children}</th>;
}
