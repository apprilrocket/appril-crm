import { createClient } from '@/lib/supabase/server';
import { BarChart3 } from 'lucide-react';
import Link from 'next/link';

export const dynamic = 'force-dynamic';

type FunnelRow = { stage_key: string; stage_label: string; stage_color: string | null; sort_order: number; leads: number };
type ChannelRow = { channel: string; sent: number; delivered: number; opened: number; clicked: number; replied: number; failed: number };
type DailyRow = { day: string; outbound: number; inbound: number; engagement: number };
type CampaignStats = { campaign_id: string; total: number; pending: number; sent: number; failed: number; delivered: number; opened: number; clicked: number; replied: number };

function pct(part: number, total: number): string {
  if (!total) return '—';
  return `${Math.round((part / total) * 100)}%`;
}

export default async function ReportsPage() {
  const supabase = await createClient();

  const [funnelRes, channelRes, dailyRes, campStatsRes, campaignsRes] = await Promise.all([
    supabase.rpc('report_funnel'),
    supabase.rpc('report_channel_stats', { p_days: 30 }),
    supabase.rpc('report_activity_daily', { p_days: 14 }),
    supabase.rpc('campaigns_overview'),
    supabase.from('campaigns').select('id, name, channel, status, started_at').order('created_at', { ascending: false })
  ]);

  const funnel: FunnelRow[] = funnelRes.data ?? [];
  const channels: ChannelRow[] = channelRes.data ?? [];
  const daily: DailyRow[] = dailyRes.data ?? [];
  const campStats: CampaignStats[] = campStatsRes.data ?? [];
  const campaigns = campaignsRes.data ?? [];

  const maxFunnel = Math.max(...funnel.map(f => Number(f.leads)), 1);
  const maxDaily = Math.max(...daily.flatMap(d => [Number(d.outbound), Number(d.inbound), Number(d.engagement)]), 1);
  const statsByCampaign = new Map(campStats.map(s => [s.campaign_id, s]));

  return (
    <div className="p-8 space-y-8">
      <div>
        <h1 className="text-2xl font-semibold text-neutral-900 flex items-center gap-2">
          <BarChart3 size={24} /> Reportes
        </h1>
        <p className="text-sm text-neutral-500 mt-1">Embudo, performance por canal y campañas — últimos 30 días salvo indicación.</p>
      </div>

      {/* Embudo */}
      <section className="bg-white border border-neutral-200 rounded-lg p-6">
        <h2 className="font-medium text-neutral-900 mb-4">Embudo de pipeline</h2>
        <div className="space-y-2">
          {funnel.map(f => (
            <div key={f.stage_key} className="flex items-center gap-3">
              <span className="w-28 text-sm text-neutral-600 shrink-0">{f.stage_label}</span>
              <div className="flex-1 bg-neutral-100 rounded h-7 overflow-hidden">
                <div
                  className="h-full rounded flex items-center px-2"
                  style={{
                    width: `${Math.max((Number(f.leads) / maxFunnel) * 100, Number(f.leads) > 0 ? 4 : 0)}%`,
                    backgroundColor: f.stage_color ?? '#94a3b8'
                  }}
                >
                  <span className="text-xs font-medium text-white">{Number(f.leads).toLocaleString('es-CO')}</span>
                </div>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Por canal */}
      <section className="bg-white border border-neutral-200 rounded-lg p-6">
        <h2 className="font-medium text-neutral-900 mb-4">Performance por canal <span className="text-xs text-neutral-400 font-normal">(30 días)</span></h2>
        {channels.length === 0 ? (
          <p className="text-sm text-neutral-500">Sin actividad en los últimos 30 días.</p>
        ) : (
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs text-neutral-500 border-b border-neutral-100">
                <th className="py-2 font-medium">Canal</th>
                <th className="py-2 font-medium text-right">Enviados</th>
                <th className="py-2 font-medium text-right">Entregados</th>
                <th className="py-2 font-medium text-right">Abiertos / leídos</th>
                <th className="py-2 font-medium text-right">Clicks</th>
                <th className="py-2 font-medium text-right">Respuestas</th>
                <th className="py-2 font-medium text-right">Fallos</th>
              </tr>
            </thead>
            <tbody>
              {channels.map(c => (
                <tr key={c.channel} className="border-b border-neutral-50">
                  <td className="py-2.5 font-medium capitalize">{c.channel}</td>
                  <td className="py-2.5 text-right">{Number(c.sent).toLocaleString('es-CO')}</td>
                  <td className="py-2.5 text-right">{Number(c.delivered).toLocaleString('es-CO')} <span className="text-neutral-400 text-xs">({pct(Number(c.delivered), Number(c.sent))})</span></td>
                  <td className="py-2.5 text-right">{Number(c.opened).toLocaleString('es-CO')} <span className="text-neutral-400 text-xs">({pct(Number(c.opened), Number(c.sent))})</span></td>
                  <td className="py-2.5 text-right">{Number(c.clicked).toLocaleString('es-CO')}</td>
                  <td className="py-2.5 text-right font-medium text-emerald-700">{Number(c.replied).toLocaleString('es-CO')}</td>
                  <td className={`py-2.5 text-right ${Number(c.failed) > 0 ? 'text-red-600 font-medium' : ''}`}>{Number(c.failed).toLocaleString('es-CO')}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {/* Actividad diaria */}
      <section className="bg-white border border-neutral-200 rounded-lg p-6">
        <h2 className="font-medium text-neutral-900 mb-1">Actividad diaria <span className="text-xs text-neutral-400 font-normal">(14 días)</span></h2>
        <div className="flex items-center gap-4 text-xs text-neutral-500 mb-4">
          <span className="flex items-center gap-1"><span className="w-2.5 h-2.5 rounded-sm bg-brand-600" /> Salientes</span>
          <span className="flex items-center gap-1"><span className="w-2.5 h-2.5 rounded-sm bg-emerald-500" /> Respuestas</span>
          <span className="flex items-center gap-1"><span className="w-2.5 h-2.5 rounded-sm bg-amber-400" /> Engagement</span>
        </div>
        <div className="flex items-end gap-1.5 h-36">
          {daily.map(d => (
            <div key={d.day} className="flex-1 flex flex-col items-center gap-1 group">
              <div className="w-full flex items-end justify-center gap-0.5 flex-1">
                <div className="w-1/3 bg-brand-600 rounded-t" style={{ height: `${(Number(d.outbound) / maxDaily) * 100}%` }} title={`${d.outbound} salientes`} />
                <div className="w-1/3 bg-emerald-500 rounded-t" style={{ height: `${(Number(d.inbound) / maxDaily) * 100}%` }} title={`${d.inbound} respuestas`} />
                <div className="w-1/3 bg-amber-400 rounded-t" style={{ height: `${(Number(d.engagement) / maxDaily) * 100}%` }} title={`${d.engagement} engagement`} />
              </div>
              <span className="text-[9px] text-neutral-400">
                {new Date(d.day + 'T12:00:00').toLocaleDateString('es-CO', { day: 'numeric', month: 'short' })}
              </span>
            </div>
          ))}
        </div>
      </section>

      {/* Campañas */}
      <section className="bg-white border border-neutral-200 rounded-lg p-6">
        <h2 className="font-medium text-neutral-900 mb-4">Comparativa de campañas</h2>
        {campaigns.length === 0 ? (
          <p className="text-sm text-neutral-500">Aún no hay campañas. Crea una en <Link href="/campaigns" className="text-brand-600 hover:underline">/campaigns</Link>.</p>
        ) : (
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs text-neutral-500 border-b border-neutral-100">
                <th className="py-2 font-medium">Campaña</th>
                <th className="py-2 font-medium">Canal</th>
                <th className="py-2 font-medium text-right">Enviados</th>
                <th className="py-2 font-medium text-right">Apertura</th>
                <th className="py-2 font-medium text-right">Respuesta</th>
                <th className="py-2 font-medium text-right">Fallos</th>
              </tr>
            </thead>
            <tbody>
              {campaigns.map(c => {
                const s = statsByCampaign.get(c.id);
                return (
                  <tr key={c.id} className="border-b border-neutral-50">
                    <td className="py-2.5">
                      <Link href={`/campaigns/${c.id}`} className="font-medium text-neutral-900 hover:text-brand-700">{c.name}</Link>
                      <span className="ml-2 text-xs text-neutral-400">{c.status}</span>
                    </td>
                    <td className="py-2.5 capitalize">{c.channel}</td>
                    <td className="py-2.5 text-right">{s ? Number(s.sent).toLocaleString('es-CO') : '—'}</td>
                    <td className="py-2.5 text-right">{s ? pct(Number(s.opened), Number(s.sent)) : '—'}</td>
                    <td className="py-2.5 text-right font-medium text-emerald-700">{s ? pct(Number(s.replied), Number(s.sent)) : '—'}</td>
                    <td className={`py-2.5 text-right ${s && Number(s.failed) > 0 ? 'text-red-600' : ''}`}>{s ? Number(s.failed).toLocaleString('es-CO') : '—'}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
