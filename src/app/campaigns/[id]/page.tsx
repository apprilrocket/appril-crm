import { createClient } from '@/lib/supabase/server';
import { notFound } from 'next/navigation';
import Link from 'next/link';
import { ChevronLeft, Mail, MessageCircle, AlertTriangle } from 'lucide-react';
import { LaunchButton } from './LaunchButton';
import { RetryFailedButton } from './RetryFailedButton';
import { relativeTime } from '@/lib/utils';
import type { ReactNode } from 'react';

type LeadResult = {
  lead_id: string;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  to_address: string | null;
  queue_status: string;
  last_error: string | null;
  sent_at: string | null;
  delivered: boolean;
  opened: boolean;
  clicked: boolean;
  replied_at: string | null;
  reply_value: string | null;
};

export const dynamic = 'force-dynamic';

export default async function CampaignDetailPage({ params }: { params: { id: string } }) {
  const supabase = await createClient();

  const { data: campaign } = await supabase
    .from('campaigns')
    .select('id, name, description, channel, status, template_keys, segment_filter, stats, scheduled_at, started_at, ended_at, created_at')
    .eq('id', params.id)
    .single();

  if (!campaign) notFound();

  // Trae el template asociado
  const templateKey = campaign.template_keys[0];
  const { data: template } = templateKey
    ? await supabase
        .from('message_templates')
        .select('name, channel, subject, wa_template_name')
        .eq('template_key', templateKey)
        .maybeSingle()
    : { data: null };

  // Segmentos y alcance estimado
  const segments: string[] = (campaign.segment_filter as any)?.marketing_segment ?? [];
  const stats = (campaign.stats as Record<string, number>) ?? {};

  // Calcula alcance real si la campaña ya se lanzó
  let reachCount = stats.total ?? 0;
  if (campaign.status === 'draft' && segments.length > 0) {
    let q = supabase.from('leads_master').select('*', { count: 'exact', head: true });
    if (segments.length > 0) q = q.in('marketing_segment', segments);
    if (campaign.channel === 'email')  q = q.eq('can_email', true).not('email', 'is', null);
    else                               q = q.eq('can_whatsapp', true).not('phone', 'is', null);
    const { count } = await q;
    reachCount = count ?? 0;
  }

  // Funnel + drill-down por lead (quién respondió, quién abrió, quién falló y por qué)
  let results: Record<string, number> | null = null;
  let leadResults: LeadResult[] = [];
  if (campaign.status !== 'draft') {
    const [{ data }, { data: perLead }] = await Promise.all([
      supabase.rpc('campaign_results', { p_campaign_id: params.id }),
      supabase.rpc('campaign_lead_results', { p_campaign_id: params.id }),
    ]);
    results = (data as Record<string, number>) ?? null;
    leadResults = (perLead as LeadResult[]) ?? [];
  }

  const responded = leadResults.filter(r => r.replied_at);
  const openedNoReply = leadResults.filter(r => !r.replied_at && (r.opened || r.clicked));
  const failedRows = leadResults.filter(r => r.queue_status === 'failed');

  // Agrupa fallidos por motivo para que el "por qué" sea evidente
  const errorGroups = new Map<string, LeadResult[]>();
  for (const f of failedRows) {
    const key = f.last_error ?? 'Sin detalle de error';
    if (!errorGroups.has(key)) errorGroups.set(key, []);
    errorGroups.get(key)!.push(f);
  }
  const sortedErrors = [...errorGroups.entries()].sort((a, b) => b[1].length - a[1].length);

  const attempted = (results?.sent ?? 0) + (results?.failed ?? 0);
  const failRate = attempted > 0 ? (results?.failed ?? 0) / attempted : 0;

  return (
    <div className="p-8 max-w-4xl">
      <Link
        href="/campaigns"
        className="inline-flex items-center gap-1 text-xs text-neutral-500 hover:text-neutral-700 mb-5"
      >
        <ChevronLeft size={14} /> Campañas
      </Link>

      <div className="flex items-start justify-between gap-4 mb-6">
        <div>
          <div className="flex items-center gap-2 mb-1">
            <h1 className="text-2xl font-semibold text-neutral-900">{campaign.name}</h1>
            <StatusBadge status={campaign.status} />
          </div>
          {campaign.description && (
            <p className="text-sm text-neutral-500">{campaign.description}</p>
          )}
        </div>

        {campaign.status === 'draft' && (
          <LaunchButton
            campaignId={campaign.id}
            estimatedLeads={reachCount}
            channel={campaign.channel}
          />
        )}
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
        {/* Canal y template */}
        <InfoCard
          title="Canal & Template"
          icon={campaign.channel === 'email' ? <Mail size={14} /> : <MessageCircle size={14} />}
        >
          <div className="space-y-1">
            <div className="text-sm font-medium text-neutral-900">{campaign.channel === 'email' ? 'Email' : 'WhatsApp'}</div>
            {template ? (
              <>
                <div className="text-sm text-neutral-700">{template.name}</div>
                {template.subject && <div className="text-xs text-neutral-500">Asunto: {template.subject}</div>}
                {template.wa_template_name && <div className="text-xs text-neutral-500 font-mono">{template.wa_template_name}</div>}
              </>
            ) : (
              <div className="text-xs text-neutral-400">{templateKey ?? '—'}</div>
            )}
          </div>
        </InfoCard>

        {/* Segmentos */}
        <InfoCard title="Segmentos">
          <div className="flex flex-wrap gap-1">
            {segments.map(s => <SegmentTag key={s} segment={s} />)}
            {segments.length === 0 && <span className="text-sm text-neutral-400">Sin filtro</span>}
          </div>
          <div className="mt-2 text-xs text-neutral-500">
            {campaign.status === 'draft'
              ? <span>~<strong>{reachCount.toLocaleString('es-CO')}</strong> leads alcanzables</span>
              : <span><strong>{(stats.total ?? 0).toLocaleString('es-CO')}</strong> leads encolados</span>
            }
          </div>
        </InfoCard>

        {/* Programación */}
        <InfoCard title="Programación">
          {campaign.scheduled_at ? (
            <div className="text-sm text-neutral-700">
              {new Date(campaign.scheduled_at).toLocaleString('es-CO')}
            </div>
          ) : campaign.status === 'draft' ? (
            <div className="text-sm text-neutral-500">Al lanzar</div>
          ) : (
            <div className="text-sm text-neutral-500">Inmediato</div>
          )}
          {campaign.started_at && (
            <div className="text-xs text-neutral-400 mt-1">
              Lanzada: {new Date(campaign.started_at).toLocaleString('es-CO')}
            </div>
          )}
        </InfoCard>
      </div>

      {/* Resultados */}
      {results && (
        <section className="bg-white border border-neutral-200 rounded-lg p-5 mb-6">
          <h2 className="text-sm font-semibold text-neutral-900 mb-4">Resultados</h2>
          <div className="grid grid-cols-3 md:grid-cols-7 gap-3">
            <Stat label="Total"      value={results.total ?? 0} />
            <Stat label="Enviados"   value={results.sent ?? 0}      color="text-neutral-900" />
            <Stat label="Fallidos"   value={results.failed ?? 0}    color="text-red-700" />
            <Stat label="Entregados" value={results.delivered ?? 0} color="text-blue-700"    pct={pct(results.delivered, results.sent)} />
            <Stat label="Abiertos"   value={results.opened ?? 0}    color="text-violet-700"  pct={pct(results.opened, results.sent)} />
            <Stat label="Clicks"     value={results.clicked ?? 0}   color="text-amber-700"   pct={pct(results.clicked, results.sent)} />
            <Stat label="Respuestas" value={results.replied ?? 0}   color="text-emerald-700" pct={pct(results.replied, results.sent)} />
          </div>
          {(results.pending ?? 0) > 0 && (
            <p className="text-xs text-neutral-500 mt-3">{results.pending} mensajes aún en cola.</p>
          )}
          <p className="text-[11px] text-neutral-400 mt-3">
            El engagement se atribuye por lead a partir del momento de su envío. Los porcentajes son sobre enviados.
          </p>
        </section>
      )}

      {/* Alerta de salud */}
      {failRate > 0.2 && attempted >= 5 && (
        <section className="bg-red-50 border border-red-300 rounded-lg p-4 mb-6">
          <div className="flex items-center gap-2 text-sm font-semibold text-red-800">
            <AlertTriangle size={15} /> {Math.round(failRate * 100)}% de los envíos fallaron
          </div>
          <p className="text-xs text-red-700 mt-1">
            Motivo principal: {sortedErrors[0]?.[0] ?? '—'} ({sortedErrors[0]?.[1].length ?? 0} mensajes).
            Revisa el detalle abajo y reintenta cuando lo corrijas.
          </p>
        </section>
      )}

      {/* Respondieron: la lista de oro */}
      {campaign.status !== 'draft' && (
        <section className="bg-white border border-emerald-200 rounded-lg overflow-hidden mb-6">
          <div className="px-5 py-3 border-b border-emerald-100 bg-emerald-50 flex items-center justify-between">
            <h2 className="text-sm font-semibold text-emerald-800">💬 Respondieron ({responded.length})</h2>
            <span className="text-xs text-emerald-600">contáctalos antes de que se enfríen</span>
          </div>
          {responded.length === 0 ? (
            <p className="px-5 py-6 text-sm text-neutral-400">Nadie ha respondido todavía.</p>
          ) : (
            <ul className="divide-y divide-neutral-50">
              {responded.map(r => (
                <li key={r.lead_id} className="px-5 py-3 flex items-center justify-between gap-3 hover:bg-neutral-50">
                  <div className="min-w-0">
                    <Link href={`/leads/${r.lead_id}`} className="text-sm font-medium text-brand-600 hover:underline">
                      {r.full_name ?? r.email ?? r.to_address}
                    </Link>
                    {r.reply_value && <div className="text-xs text-neutral-600 truncate">"{r.reply_value}"</div>}
                  </div>
                  <div className="flex items-center gap-3 shrink-0">
                    <span className="text-xs text-neutral-400">{relativeTime(r.replied_at)}</span>
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
          )}
        </section>
      )}

      {/* Abrieron sin responder: candidatos a follow-up */}
      {openedNoReply.length > 0 && (
        <section className="bg-white border border-neutral-200 rounded-lg overflow-hidden mb-6">
          <div className="px-5 py-3 border-b border-neutral-100 bg-neutral-50 flex items-center justify-between">
            <h2 className="text-sm font-medium text-neutral-700">👀 Abrieron sin responder ({openedNoReply.length})</h2>
            <span className="text-xs text-neutral-400">mostraron interés — buen objetivo para un follow-up</span>
          </div>
          <ul className="divide-y divide-neutral-50">
            {openedNoReply.map(r => (
              <li key={r.lead_id} className="px-5 py-2.5 flex items-center justify-between gap-3 hover:bg-neutral-50">
                <Link href={`/leads/${r.lead_id}`} className="text-sm text-brand-600 hover:underline truncate">
                  {r.full_name ?? r.email ?? r.to_address}
                </Link>
                <span className="text-xs text-neutral-400 shrink-0">
                  {r.clicked ? 'abrió e hizo click' : 'abrió'} · enviado {relativeTime(r.sent_at)}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Fallidos agrupados por motivo */}
      {failedRows.length > 0 && (
        <section className="bg-white border border-red-200 rounded-lg overflow-hidden">
          <div className="px-5 py-3 border-b border-red-100 bg-red-50 flex items-center justify-between gap-3 flex-wrap">
            <h2 className="text-sm font-semibold text-red-800">⚠️ Fallidos ({failedRows.length})</h2>
            <RetryFailedButton campaignId={campaign.id} failedCount={failedRows.length} />
          </div>
          <div className="divide-y divide-neutral-100">
            {sortedErrors.map(([errorMsg, rows]) => (
              <details key={errorMsg} className="group">
                <summary className="px-5 py-3 cursor-pointer hover:bg-neutral-50 flex items-center justify-between gap-3 list-none">
                  <span className="text-sm text-neutral-800 min-w-0 truncate">{errorMsg}</span>
                  <span className="text-xs text-red-600 font-medium shrink-0">{rows.length} mensajes</span>
                </summary>
                <ul className="px-5 pb-3 space-y-1">
                  {rows.slice(0, 25).map(r => (
                    <li key={r.lead_id} className="text-xs flex items-center justify-between gap-3">
                      <Link href={`/leads/${r.lead_id}`} className="text-brand-600 hover:underline truncate">
                        {r.full_name ?? r.email ?? r.to_address}
                      </Link>
                      <span className="text-neutral-400 font-mono shrink-0">{r.to_address}</span>
                    </li>
                  ))}
                  {rows.length > 25 && (
                    <li className="text-xs text-neutral-400">… y {rows.length - 25} más con el mismo error</li>
                  )}
                </ul>
              </details>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}

function InfoCard({ title, icon, children }: { title: string; icon?: ReactNode; children: ReactNode }) {
  return (
    <div className="bg-white border border-neutral-200 rounded-lg p-4">
      <div className="flex items-center gap-1.5 text-xs font-medium text-neutral-500 mb-3">
        {icon} {title}
      </div>
      {children}
    </div>
  );
}

function Stat({ label, value, color = 'text-neutral-900', pct }: { label: string; value: number; color?: string; pct?: string | null }) {
  return (
    <div>
      <div className="text-xs text-neutral-400">{label}</div>
      <div className={`text-xl font-semibold mt-0.5 ${color}`}>{value.toLocaleString('es-CO')}</div>
      {pct && <div className="text-[11px] text-neutral-400">{pct}</div>}
    </div>
  );
}

function pct(n: number | undefined, base: number | undefined): string | null {
  if (!n || !base) return null;
  return `${Math.round((n / base) * 100)}%`;
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
    cancelled: 'bg-neutral-100 text-neutral-500',
  };
  const labels: Record<string, string> = {
    draft: 'Borrador', scheduled: 'Programada', running: 'Enviando',
    completed: 'Completada', done: 'Completada', cancelled: 'Cancelada'
  };
  return (
    <span className={`text-xs px-2.5 py-1 rounded-full font-medium ${styles[status] ?? 'bg-neutral-100 text-neutral-600'}`}>
      {labels[status] ?? status}
    </span>
  );
}

