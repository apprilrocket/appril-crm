import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { ArrowRight, Flame, AlertTriangle, PhoneCall, CalendarClock } from 'lucide-react';
import { SegmentBadge, StageBadge, HeatBadge } from '@/components/SegmentBadge';
import { relativeTime } from '@/lib/utils';
import { eventMeta, eventDetail } from '@/lib/events';

export const dynamic = 'force-dynamic';

type NeedingReply = {
  lead_id: string;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  marketing_segment: string | null;
  pipeline_stage: string | null;
  engagement_score: number | null;
  replied_at: string;
  reply_value: string | null;
  reply_channel: string | null;
};

export default async function HomePage() {
  const supabase = await createClient();
  const nowIso = new Date().toISOString();

  // KPIs principales
  const [
    { count: totalLeads },
    { count: superHot },
    { count: hot },
    { count: warm },
    { count: cold },
    { count: doNotEmail },
  ] = await Promise.all([
    supabase.from('leads_master').select('*', { count: 'exact', head: true }),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('marketing_segment', 'SUPER_HOT'),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('marketing_segment', 'HOT'),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('marketing_segment', 'WARM'),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('marketing_segment', 'COLD'),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('marketing_segment', 'DO_NOT_EMAIL'),
  ]);

  // Bloque "Hoy": respuestas sin atender, tareas vencidas, campañas con problemas
  const cutoff = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString();
  const [
    { data: needReply },
    { data: dueTasks },
    { data: campaignRows },
    { data: overview },
    { data: recentEvents },
    { data: warmingLeads },
    { data: stageRows },
  ] = await Promise.all([
    supabase.rpc('leads_needing_reply', { p_limit: 6 }),
    supabase
      .from('lead_tasks')
      .select('id, title, due_at, lead_id, leads_master(full_name, email)')
      .eq('status', 'open')
      .lte('due_at', nowIso)
      .order('due_at')
      .limit(5),
    supabase.from('campaigns').select('id, name, channel, status, started_at').neq('status', 'draft'),
    supabase.rpc('campaigns_overview'),
    supabase
      .from('lead_events')
      .select('id, event_type, event_channel, event_value, metadata, created_at, lead_id')
      .order('created_at', { ascending: false })
      .limit(8),
    supabase
      .from('leads_master')
      .select('id, full_name, email, marketing_segment, pipeline_stage, engagement_score, last_engaged_at')
      .gt('engagement_score', 0)
      .gte('last_engaged_at', cutoff)
      .order('engagement_score', { ascending: false })
      .limit(8),
    supabase.from('pipeline_stages').select('key, label, color').order('position'),
  ]);
  const stageMap = new Map((stageRows ?? []).map(s => [s.key, s]));

  // Nombres de los leads de la actividad reciente (lead_events no tiene FK a leads_master)
  const eventLeadIds = [...new Set((recentEvents ?? []).map(e => e.lead_id).filter(Boolean))];
  const { data: eventLeads } = eventLeadIds.length
    ? await supabase.from('leads_master').select('id, full_name, email').in('id', eventLeadIds)
    : { data: [] as { id: string; full_name: string | null; email: string | null }[] };
  const eventLeadMap = new Map((eventLeads ?? []).map(l => [l.id, l]));

  // Campañas con tasa de fallo > 20% (solo las que ya enviaron algo)
  const statsById = new Map((overview ?? []).map((o: any) => [o.campaign_id, o]));
  const sickCampaigns = (campaignRows ?? [])
    .map(c => {
      const s: any = statsById.get(c.id);
      if (!s) return null;
      const attempted = Number(s.sent) + Number(s.failed);
      if (attempted < 5) return null;
      const failRate = Number(s.failed) / attempted;
      return failRate > 0.2 ? { ...c, failed: Number(s.failed), attempted, failRate } : null;
    })
    .filter(Boolean) as Array<{ id: string; name: string; failed: number; attempted: number; failRate: number }>;

  const replies = (needReply ?? []) as NeedingReply[];
  const hasTodayItems = replies.length > 0 || (dueTasks ?? []).length > 0 || sickCampaigns.length > 0;

  return (
    <div className="p-8 max-w-7xl">
      <h1 className="text-2xl font-semibold text-neutral-900">Inicio</h1>
      <p className="text-sm text-neutral-500 mt-1">Foto general del motor de marketing.</p>

      {/* HOY: lo que requiere acción inmediata */}
      <section className="mt-6 bg-white border-2 border-neutral-900 rounded-lg p-5">
        <h2 className="text-sm font-semibold text-neutral-900 mb-1">📋 Hoy</h2>
        <p className="text-xs text-neutral-500 mb-4">Lo más importante que puedes hacer ahora, en orden de prioridad.</p>

        {!hasTodayItems && (
          <p className="text-sm text-neutral-500">
            ✅ Nada urgente. No hay respuestas sin atender, tareas vencidas ni campañas con problemas.
          </p>
        )}

        {replies.length > 0 && (
          <div className="mb-4">
            <h3 className="text-xs font-semibold text-emerald-700 uppercase tracking-wide mb-2 inline-flex items-center gap-1">
              <PhoneCall size={12} /> Respondieron y nadie los ha contactado
            </h3>
            <ul className="space-y-2">
              {replies.map(r => (
                <li key={r.lead_id} className="flex items-start justify-between gap-3 bg-emerald-50 border border-emerald-200 rounded-md px-3 py-2">
                  <div className="min-w-0">
                    <Link href={`/leads/${r.lead_id}`} className="text-sm font-medium text-emerald-900 hover:underline">
                      {r.full_name ?? r.email ?? r.phone ?? 'Sin nombre'}
                    </Link>
                    <span className="ml-2 text-xs text-emerald-700">
                      respondió por {r.reply_channel === 'whatsapp' ? 'WhatsApp' : r.reply_channel ?? '—'} {relativeTime(r.replied_at)}
                    </span>
                    {r.reply_value && (
                      <div className="text-xs text-emerald-800 mt-0.5 truncate">"{r.reply_value}"</div>
                    )}
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <SegmentBadge segment={r.marketing_segment} />
                    <Link
                      href={`/leads/${r.lead_id}`}
                      className="text-xs bg-emerald-600 text-white px-2.5 py-1 rounded-md hover:bg-emerald-700"
                    >
                      Contactar
                    </Link>
                  </div>
                </li>
              ))}
            </ul>
          </div>
        )}

        {(dueTasks ?? []).length > 0 && (
          <div className="mb-4">
            <h3 className="text-xs font-semibold text-amber-700 uppercase tracking-wide mb-2 inline-flex items-center gap-1">
              <CalendarClock size={12} /> Tareas vencidas
            </h3>
            <ul className="space-y-1.5">
              {(dueTasks ?? []).map((t: any) => (
                <li key={t.id} className="flex items-center justify-between gap-3 text-sm">
                  <div className="min-w-0 truncate">
                    <Link href={`/leads/${t.lead_id}`} className="font-medium text-brand-600 hover:underline">
                      {t.leads_master?.full_name ?? t.leads_master?.email ?? 'Lead'}
                    </Link>
                    <span className="text-neutral-600"> — {t.title}</span>
                  </div>
                  <span className="text-xs text-amber-700 shrink-0">vencía {relativeTime(t.due_at)}</span>
                </li>
              ))}
            </ul>
          </div>
        )}

        {sickCampaigns.length > 0 && (
          <div>
            <h3 className="text-xs font-semibold text-red-700 uppercase tracking-wide mb-2 inline-flex items-center gap-1">
              <AlertTriangle size={12} /> Campañas con fallos altos
            </h3>
            <ul className="space-y-1.5">
              {sickCampaigns.map(c => (
                <li key={c.id} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5 text-sm">
                  <Link href={`/campaigns/${c.id}`} className="font-medium text-red-700 hover:underline truncate">
                    {c.name}
                  </Link>
                  <span className="text-xs text-red-600">
                    {c.failed} de {c.attempted} fallaron ({Math.round(c.failRate * 100)}%) — revisar por qué
                  </span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </section>

      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mt-6">
        <KpiCard label="Total leads"    value={totalLeads ?? 0}    href="/leads" />
        <KpiCard label="SUPER HOT"      value={superHot ?? 0}      href="/leads?segment=SUPER_HOT"   color="text-red-700" />
        <KpiCard label="HOT"            value={hot ?? 0}           href="/leads?segment=HOT"         color="text-orange-700" />
        <KpiCard label="WARM"           value={warm ?? 0}          href="/leads?segment=WARM"        color="text-yellow-700" />
        <KpiCard label="COLD"           value={cold ?? 0}          href="/leads?segment=COLD"        color="text-blue-700" />
        <KpiCard label="No contactar"   value={doNotEmail ?? 0}    href="/leads?segment=DO_NOT_EMAIL" color="text-neutral-600" />
      </div>

      <section className="mt-6 bg-white border border-orange-200 rounded-lg p-5">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-semibold text-neutral-900 inline-flex items-center gap-1.5">
            <Flame size={16} className="text-orange-500" /> Leads calentándose
            <span className="text-xs font-normal text-neutral-400">(engagement últimos 14 días)</span>
          </h2>
          <Link href="/leads?warming=1&sort=heat" className="text-xs text-brand-600 hover:underline inline-flex items-center gap-1">
            Ver todos <ArrowRight size={12} />
          </Link>
        </div>
        {warmingLeads && warmingLeads.length > 0 ? (
          <ul className="divide-y divide-neutral-100">
            {warmingLeads.map(l => {
              const st = stageMap.get(l.pipeline_stage ?? 'new');
              return (
                <li key={l.id} className="py-2 flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <Link href={`/leads/${l.id}`} className="text-sm font-medium text-brand-600 hover:underline">
                      {l.full_name ?? l.email ?? 'sin nombre'}
                    </Link>
                    <span className="ml-2 text-xs text-neutral-400">{relativeTime(l.last_engaged_at)}</span>
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <HeatBadge score={l.engagement_score} lastEngagedAt={l.last_engaged_at} />
                    <SegmentBadge segment={l.marketing_segment} />
                    <StageBadge stage={st?.label ?? l.pipeline_stage ?? 'new'} color={st?.color} />
                  </div>
                </li>
              );
            })}
          </ul>
        ) : (
          <p className="text-sm text-neutral-500">
            Nadie se está calentando todavía. Cuando un lead abra, haga click o responda, aparece aquí automáticamente.
          </p>
        )}
      </section>

      <section className="mt-6 bg-white border border-neutral-200 rounded-lg p-5">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-semibold text-neutral-900">Actividad reciente</h2>
          <Link href="/leads" className="text-xs text-brand-600 hover:underline inline-flex items-center gap-1">
            Ver leads <ArrowRight size={12} />
          </Link>
        </div>
        {recentEvents && recentEvents.length > 0 ? (
          <ul className="divide-y divide-neutral-100">
            {recentEvents.map((e: any) => {
              const meta = eventMeta(e.event_type);
              const detail = eventDetail(e);
              const leadInfo = eventLeadMap.get(e.lead_id);
              const who = leadInfo?.full_name ?? leadInfo?.email ?? 'Lead';
              return (
                <li key={e.id} className="py-2 text-sm flex items-center justify-between gap-3">
                  <span className="text-neutral-700 min-w-0 truncate">
                    {meta.icon}{' '}
                    <Link href={`/leads/${e.lead_id}`} className="font-medium text-brand-600 hover:underline">{who}</Link>
                    {' '}<span className="lowercase">{meta.label}</span>
                    {detail && <span className="text-neutral-400"> · {detail}</span>}
                  </span>
                  <span className="text-xs text-neutral-400 shrink-0">{relativeTime(e.created_at)}</span>
                </li>
              );
            })}
          </ul>
        ) : (
          <p className="text-sm text-neutral-500">
            Aún no hay actividad. Cuando empieces a enviar mensajes, aquí verás opens, clicks, replies y conversiones.
          </p>
        )}
      </section>
    </div>
  );
}

function KpiCard({ label, value, href, color = 'text-neutral-900' }: { label: string; value: number; href: string; color?: string }) {
  return (
    <Link href={href} className="block bg-white border border-neutral-200 rounded-lg p-4 hover:border-neutral-300 transition-colors">
      <div className="text-xs text-neutral-500">{label}</div>
      <div className={`text-2xl font-semibold mt-1 ${color}`}>{value.toLocaleString('es-CO')}</div>
    </Link>
  );
}
