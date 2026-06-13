import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { Plus, Megaphone } from 'lucide-react';

export const dynamic = 'force-dynamic';

type Campaign = {
  id: string;
  name: string;
  channel: string;
  status: string;
  stats: Record<string, number> | null;
  template_keys: string[];
  segment_filter: Record<string, any>;
  scheduled_at: string | null;
  started_at: string | null;
  created_at: string;
};

type Overview = {
  campaign_id: string;
  total: number;
  pending: number;
  sent: number;
  failed: number;
  delivered: number;
  opened: number;
  clicked: number;
  replied: number;
};

export default async function CampaignsPage() {
  const supabase = await createClient();

  const [{ data: campaigns }, { data: overviewRows }] = await Promise.all([
    supabase
      .from('campaigns')
      .select('id, name, channel, status, stats, template_keys, segment_filter, scheduled_at, started_at, created_at')
      .order('created_at', { ascending: false }),
    supabase.rpc('campaigns_overview'),
  ]);

  const overview = new Map<string, Overview>(
    ((overviewRows ?? []) as Overview[]).map(o => [o.campaign_id, o])
  );

  // Comparativa global: solo campañas que ya intentaron enviar
  const launched = (campaigns ?? [])
    .map(c => ({ c, o: overview.get(c.id) }))
    .filter((x): x is { c: Campaign; o: Overview } => !!x.o && (Number(x.o.sent) + Number(x.o.failed)) > 0);

  const totalSent = launched.reduce((acc, x) => acc + Number(x.o.sent), 0);
  const totalReplied = launched.reduce((acc, x) => acc + Number(x.o.replied), 0);
  const totalOpened = launched.reduce((acc, x) => acc + Number(x.o.opened), 0);

  const ranked = launched
    .filter(x => Number(x.o.sent) >= 1)
    .map(x => ({ ...x, replyRate: Number(x.o.replied) / Math.max(1, Number(x.o.sent)) }))
    .sort((a, b) => b.replyRate - a.replyRate);
  const best = ranked.find(x => x.replyRate > 0) ?? null;

  const channelRate = (channel: string) => {
    const rows = launched.filter(x => x.c.channel === channel);
    const sent = rows.reduce((acc, x) => acc + Number(x.o.sent), 0);
    const replied = rows.reduce((acc, x) => acc + Number(x.o.replied), 0);
    const opened = rows.reduce((acc, x) => acc + Number(x.o.opened), 0);
    return { sent, replied, opened };
  };
  const emailStats = channelRate('email');
  const waStats = channelRate('whatsapp');

  return (
    <div className="p-8 max-w-5xl">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-neutral-900">Campañas</h1>
          <p className="text-sm text-neutral-500 mt-1">
            Envíos masivos a segmentos. Crea, programa y lanza campañas de email o WhatsApp.
          </p>
        </div>
        <Link
          href="/campaigns/new"
          className="inline-flex items-center gap-2 bg-neutral-900 text-white text-sm px-4 py-2 rounded-md hover:bg-neutral-800 transition-colors"
        >
          <Plus size={15} /> Nueva campaña
        </Link>
      </div>

      {launched.length > 0 && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
          <OverviewCard label="Enviados (todas)" value={totalSent.toLocaleString('es-CO')} />
          <OverviewCard
            label="Tasa de respuesta"
            value={totalSent > 0 ? `${Math.round((totalReplied / totalSent) * 100)}%` : '—'}
            hint={`${totalReplied} respuestas · ${totalOpened} aperturas`}
          />
          <OverviewCard
            label="Mejor campaña"
            value={best ? best.c.name.replace(/^Outreach · /, '') : '—'}
            hint={best ? `${Math.round(best.replyRate * 100)}% de respuesta` : 'aún sin respuestas'}
            small
          />
          <OverviewCard
            label="Email vs WhatsApp"
            value={`${emailStats.sent > 0 ? Math.round((emailStats.replied / emailStats.sent) * 100) : 0}% vs ${waStats.sent > 0 ? Math.round((waStats.replied / waStats.sent) * 100) : 0}%`}
            hint="tasa de respuesta por canal"
          />
        </div>
      )}

      {(!campaigns || campaigns.length === 0) ? (
        <Empty />
      ) : (
        <div className="space-y-3">
          {campaigns.map(c => (
            <CampaignRow key={c.id} campaign={c} overview={overview.get(c.id)} />
          ))}
        </div>
      )}
    </div>
  );
}

function OverviewCard({ label, value, hint, small }: { label: string; value: string; hint?: string; small?: boolean }) {
  return (
    <div className="bg-white border border-neutral-200 rounded-lg p-4">
      <div className="text-xs text-neutral-500">{label}</div>
      <div className={`font-semibold mt-1 text-neutral-900 ${small ? 'text-sm truncate' : 'text-xl'}`} title={value}>{value}</div>
      {hint && <div className="text-[11px] text-neutral-400 mt-0.5">{hint}</div>}
    </div>
  );
}

function CampaignRow({ campaign: c, overview }: { campaign: Campaign; overview?: Overview }) {
  const segments: string[] = c.segment_filter?.marketing_segment ?? [];
  const stats = c.stats ?? {};
  // Datos en vivo del funnel si existen; si no, el snapshot guardado en stats
  const total   = overview ? Number(overview.total)  : (stats.total ?? 0);
  const sent    = overview ? Number(overview.sent)   : (stats.sent ?? 0);
  const failed  = overview ? Number(overview.failed) : (stats.failed ?? 0);
  const opened  = overview ? Number(overview.opened) : (stats.opened ?? 0);
  const replied = overview ? Number(overview.replied): (stats.replied ?? 0);
  const attempted = sent + failed;
  const failRate = attempted > 0 ? failed / attempted : 0;

  return (
    <Link
      href={`/campaigns/${c.id}`}
      className="block bg-white border border-neutral-200 rounded-lg px-5 py-4 hover:border-neutral-300 transition-colors"
    >
      <div className="flex items-start justify-between gap-4">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-1">
            <span className="text-sm font-medium text-neutral-900 truncate">{c.name}</span>
            <ChannelBadge channel={c.channel} />
          </div>
          <div className="flex flex-wrap gap-1">
            {segments.map(s => (
              <SegmentTag key={s} segment={s} />
            ))}
            {segments.length === 0 && (
              <span className="text-xs text-neutral-400">Sin filtro de segmento</span>
            )}
          </div>
        </div>

        <div className="flex items-center gap-4 shrink-0">
          {c.status === 'running' || c.status === 'completed' || c.status === 'done' ? (
            <div className="text-right">
              <div className="text-xs text-neutral-400">Enviados / Total</div>
              <div className="text-sm font-medium text-neutral-900">
                {sent.toLocaleString('es-CO')} / {total.toLocaleString('es-CO')}
              </div>
              <div className="text-xs text-neutral-500">
                {opened > 0 && <span className="text-blue-700">{opened} abiertos</span>}
                {opened > 0 && replied > 0 && ' · '}
                {replied > 0 && <span className="text-emerald-700">{replied} respuestas</span>}
              </div>
              {failed > 0 && (
                <div className={`text-xs ${failRate > 0.2 && attempted >= 5 ? 'font-semibold text-red-700' : 'text-red-600'}`}>
                  {failRate > 0.2 && attempted >= 5 ? '⚠️ ' : ''}{failed} fallidos{attempted >= 5 ? ` (${Math.round(failRate * 100)}%)` : ''}
                </div>
              )}
            </div>
          ) : c.status === 'draft' && total > 0 ? (
            <div className="text-right">
              <div className="text-xs text-neutral-400">Alcance estimado</div>
              <div className="text-sm font-medium text-neutral-900">{total.toLocaleString('es-CO')} leads</div>
            </div>
          ) : null}
          <StatusBadge status={c.status} />
        </div>
      </div>

      {c.started_at && (
        <div className="mt-2 text-xs text-neutral-400">
          Lanzada {new Date(c.started_at).toLocaleString('es-CO')}
        </div>
      )}
    </Link>
  );
}

function Empty() {
  return (
    <div className="bg-white border border-neutral-200 rounded-lg px-8 py-16 text-center">
      <Megaphone className="w-8 h-8 text-neutral-300 mx-auto mb-3" />
      <p className="text-sm font-medium text-neutral-700">Aún no hay campañas</p>
      <p className="text-sm text-neutral-400 mt-1">Crea tu primera campaña para enviar a un segmento.</p>
      <Link
        href="/campaigns/new"
        className="inline-flex items-center gap-2 mt-4 bg-neutral-900 text-white text-sm px-4 py-2 rounded-md hover:bg-neutral-800"
      >
        <Plus size={14} /> Nueva campaña
      </Link>
    </div>
  );
}

function ChannelBadge({ channel }: { channel: string }) {
  return (
    <span className={`inline-block text-xs px-2 py-0.5 rounded-full font-medium ${
      channel === 'email' ? 'bg-blue-50 text-blue-700' : 'bg-green-50 text-green-700'
    }`}>
      {channel === 'email' ? '✉ Email' : '💬 WhatsApp'}
    </span>
  );
}

const segmentColors: Record<string, string> = {
  SUPER_HOT: 'bg-red-100 text-red-700',
  HOT:       'bg-orange-100 text-orange-700',
  WARM:      'bg-yellow-100 text-yellow-700',
  COLD:      'bg-sky-100 text-sky-700',
};

function SegmentTag({ segment }: { segment: string }) {
  return (
    <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${segmentColors[segment] ?? 'bg-neutral-100 text-neutral-600'}`}>
      {segment}
    </span>
  );
}

function StatusBadge({ status }: { status: string }) {
  const styles: Record<string, string> = {
    draft:     'bg-neutral-100 text-neutral-600',
    scheduled: 'bg-violet-50 text-violet-700',
    running:   'bg-blue-50 text-blue-700',
    completed: 'bg-emerald-50 text-emerald-700',
    done:      'bg-emerald-50 text-emerald-700',
    paused:    'bg-amber-50 text-amber-700',
    cancelled: 'bg-neutral-100 text-neutral-500',
  };
  const labels: Record<string, string> = {
    draft:     'Borrador',
    scheduled: 'Programada',
    running:   'Enviando',
    completed: 'Completada',
    done:      'Completada',
    paused:    'Pausada',
    cancelled: 'Cancelada',
  };
  return (
    <span className={`text-xs px-2.5 py-1 rounded-full font-medium ${styles[status] ?? 'bg-neutral-100 text-neutral-600'}`}>
      {labels[status] ?? status}
    </span>
  );
}
