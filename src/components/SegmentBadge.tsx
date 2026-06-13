import { cn } from '@/lib/utils';

const COLORS: Record<string, string> = {
  SUPER_HOT:    'bg-red-100 text-red-800',
  HOT:          'bg-orange-100 text-orange-800',
  WARM:         'bg-yellow-100 text-yellow-800',
  COLD:         'bg-blue-100 text-blue-800',
  DO_NOT_EMAIL: 'bg-neutral-200 text-neutral-700',
  UNKNOWN:      'bg-neutral-100 text-neutral-500'
};

export function SegmentBadge({ segment }: { segment: string | null }) {
  const key = segment ?? 'UNKNOWN';
  return (
    <span className={cn('inline-flex items-center px-2 py-0.5 rounded text-xs font-medium', COLORS[key] ?? COLORS.UNKNOWN)}>
      {key}
    </span>
  );
}

export function StageBadge({ stage, color }: { stage: string; color?: string | null }) {
  return (
    <span
      className="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium text-white"
      style={{ backgroundColor: color ?? '#94a3b8' }}
    >
      {stage}
    </span>
  );
}

// Heat = engagement acumulado. "Calentándose" si hubo actividad en los últimos 14 días.
const WARMING_WINDOW_MS = 14 * 24 * 60 * 60 * 1000;

export function isWarming(score: number | null, lastEngagedAt: string | null) {
  if (!score || !lastEngagedAt) return false;
  return Date.now() - new Date(lastEngagedAt).getTime() < WARMING_WINDOW_MS;
}

// Niveles de heat en lenguaje humano. El score real va de 1 a ~260 pero la acción
// cambia en estos umbrales: 8+ amerita toque personal, 20+ amerita llamada.
export function heatLevel(score: number | null): { label: string; color: string; bar: string } | null {
  if (!score || score <= 0) return null;
  if (score >= 20) return { label: 'Muy caliente', color: 'text-red-600',    bar: 'bg-red-500' };
  if (score >= 8)  return { label: 'Caliente',     color: 'text-orange-500', bar: 'bg-orange-400' };
  return             { label: 'Tibio',             color: 'text-amber-500',  bar: 'bg-amber-300' };
}

export function HeatBadge({ score, lastEngagedAt }: { score: number | null; lastEngagedAt: string | null }) {
  const level = heatLevel(score);
  if (!level) return <span className="text-xs text-neutral-300">—</span>;
  const warming = isWarming(score, lastEngagedAt);
  return (
    <span
      className={cn('inline-flex items-center gap-0.5 text-xs font-semibold', warming ? level.color : 'text-neutral-400')}
      title={warming ? `${level.label} · engagement en los últimos 14 días` : `${level.label} · sin actividad reciente`}
    >
      {warming ? '🔥' : '·'} {score}
    </span>
  );
}

// Barra de heat con escala y label: para el detalle de lead, donde hay espacio
export function HeatBar({ score, lastEngagedAt }: { score: number | null; lastEngagedAt: string | null }) {
  const level = heatLevel(score);
  if (!level) {
    return <span className="text-xs text-neutral-400">Sin engagement todavía</span>;
  }
  const warming = isWarming(score, lastEngagedAt);
  const pct = Math.min(100, Math.round(((score ?? 0) / 40) * 100));
  return (
    <div>
      <div className="flex items-center justify-between text-xs mb-1">
        <span className={cn('font-semibold', warming ? level.color : 'text-neutral-500')}>
          {warming ? '🔥 ' : ''}{level.label} · {score}
        </span>
        <span className="text-neutral-400">{warming ? 'activo últimos 14 días' : 'sin actividad reciente'}</span>
      </div>
      <div className="h-1.5 rounded-full bg-neutral-100 overflow-hidden">
        <div
          className={cn('h-full rounded-full', warming ? level.bar : 'bg-neutral-300')}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}
