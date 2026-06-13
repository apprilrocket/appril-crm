'use client';

import { useState } from 'react';
import { eventMeta, eventDetail, EVENT_TONE_CLASSES, type EventCategory } from '@/lib/events';
import { relativeTime, cn } from '@/lib/utils';

type LeadEvent = {
  id: string;
  event_type: string;
  event_channel: string | null;
  event_value: string | null;
  metadata: any;
  created_at: string | null;
};

const FILTERS: { key: EventCategory | 'all'; label: string }[] = [
  { key: 'all',        label: 'Todo' },
  { key: 'reply',      label: '💬 Respuestas' },
  { key: 'engagement', label: '👀 Engagement' },
  { key: 'outbound',   label: '📤 Envíos' },
  { key: 'system',     label: '⚙️ Sistema' },
];

export function Timeline({ events }: { events: LeadEvent[] }) {
  const [filter, setFilter] = useState<EventCategory | 'all'>('all');

  const visible = filter === 'all'
    ? events
    : events.filter(e => eventMeta(e.event_type).category === filter);

  return (
    <div>
      <div className="flex flex-wrap gap-1.5 mb-4">
        {FILTERS.map(f => (
          <button
            key={f.key}
            onClick={() => setFilter(f.key)}
            className={cn(
              'text-xs px-2.5 py-1 rounded-full border transition-colors',
              filter === f.key
                ? 'bg-neutral-900 text-white border-neutral-900'
                : 'bg-white text-neutral-600 border-neutral-200 hover:border-neutral-400'
            )}
          >
            {f.label}
          </button>
        ))}
      </div>

      {visible.length === 0 ? (
        <p className="text-sm text-neutral-500">
          {events.length === 0 ? 'Sin actividad registrada todavía.' : 'Sin eventos de este tipo.'}
        </p>
      ) : (
        <ul className="space-y-3">
          {visible.map(e => {
            const meta = eventMeta(e.event_type);
            const detail = eventDetail(e);
            return (
              <li key={e.id} className="flex items-start gap-3 text-sm">
                <span className={cn('w-2 h-2 mt-2 rounded-full shrink-0', EVENT_TONE_CLASSES[meta.tone])} />
                <div className="flex-1 min-w-0">
                  <div className="text-neutral-900">
                    {meta.icon} {meta.label}
                    {e.event_channel && <span className="text-xs text-neutral-400"> · {e.event_channel}</span>}
                  </div>
                  {detail && <div className="text-xs text-neutral-600 mt-0.5">{detail}</div>}
                  <div
                    className="text-xs text-neutral-400 mt-0.5"
                    title={e.created_at ? new Date(e.created_at).toLocaleString('es-CO') : undefined}
                  >
                    {relativeTime(e.created_at)}
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
