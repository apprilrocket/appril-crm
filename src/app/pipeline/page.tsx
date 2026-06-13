import { createClient } from '@/lib/supabase/server';
import { PipelineBoard, type BoardLead } from './PipelineBoard';
import { nextActionForLead } from '@/lib/nextAction';

export const dynamic = 'force-dynamic';

export default async function PipelinePage() {
  const supabase = await createClient();

  const [{ data: stages }, { data: allLeads }] = await Promise.all([
    supabase
      .from('pipeline_stages')
      .select('key, label, color, position')
      .order('position'),
    // Una sola query para todos los leads del pipeline (top 25 × etapa = 150 max)
    supabase
      .from('leads_master')
      .select('id, full_name, email, phone, marketing_segment, pagando_hoy, pipeline_stage, engagement_score, last_engaged_at, last_contacted_at')
      .order('updated_at', { ascending: false })
      .limit(200),
  ]);

  if (!stages || stages.length === 0) {
    return <div className="p-8 text-sm text-neutral-500">No hay etapas configuradas.</div>;
  }

  // Agrupa los leads por etapa en JavaScript (sin N+1 queries)
  const leadsByStage = new Map<string, NonNullable<typeof allLeads>>(
    stages.map(s => [s.key, []])
  );
  for (const lead of allLeads ?? []) {
    const bucket = leadsByStage.get(lead.pipeline_stage ?? '');
    if (bucket && bucket.length < 25) bucket.push(lead);
  }

  // Último envío y última respuesta de los leads visibles (1 query bulk)
  const visibleIds = [...leadsByStage.values()].flat().map(l => l.id);
  const { data: events } = visibleIds.length
    ? await supabase
        .from('lead_events')
        .select('lead_id, event_type, event_value, created_at')
        .in('lead_id', visibleIds)
        .in('event_type', ['message_sent', 'wa_reply', 'email_replied', 'contact_submitted', 'discovery_form_submitted'])
        .order('created_at', { ascending: false })
        .limit(2000)
    : { data: [] as any[] };

  const lastSent = new Map<string, { value: string | null; at: string }>();
  const lastReply = new Map<string, { value: string | null; at: string }>();
  for (const e of events ?? []) {
    if (e.event_type === 'message_sent') {
      if (!lastSent.has(e.lead_id)) lastSent.set(e.lead_id, { value: e.event_value, at: e.created_at });
    } else if (!lastReply.has(e.lead_id)) {
      lastReply.set(e.lead_id, { value: e.event_value, at: e.created_at });
    }
  }

  // Totales reales por etapa (1 query paralelo con count)
  const stageCounts = await Promise.all(
    stages.map(s =>
      supabase
        .from('leads_master')
        .select('*', { count: 'exact', head: true })
        .eq('pipeline_stage', s.key)
        .then(({ count }) => ({ key: s.key, count: count ?? 0 }))
    )
  );
  const countMap = new Map(stageCounts.map(s => [s.key, s.count]));

  const now = Date.now();
  const stageData = stages.map(s => ({
    stage: s,
    leads: (leadsByStage.get(s.key) ?? []).map((l): BoardLead => {
      const sent = lastSent.get(l.id) ?? null;
      const reply = lastReply.get(l.id) ?? null;
      return {
        id: l.id,
        full_name: l.full_name,
        email: l.email,
        phone: l.phone,
        marketing_segment: l.marketing_segment,
        pagando_hoy: l.pagando_hoy,
        engagement_score: l.engagement_score,
        last_engaged_at: l.last_engaged_at,
        last_sent: sent,
        last_reply: reply,
        action: nextActionForLead({
          email: l.email,
          phone: l.phone,
          engagement_score: l.engagement_score,
          last_engaged_at: l.last_engaged_at,
          last_contacted_at: l.last_contacted_at,
          pipeline_stage: s.key,
          lastSentAt: sent?.at ?? null,
          lastReplyAt: reply?.at ?? null,
        }, now)
      };
    }),
    total: countMap.get(s.key) ?? 0,
  }));

  // Métricas del embudo: leads en gestión, estancados y respuestas sin atender
  const staleCutoff = new Date(now - 30 * 24 * 60 * 60 * 1000).toISOString();
  const inFunnel = stageCounts
    .filter(s => !['new', 'converted', 'lost'].includes(s.key))
    .reduce((acc, s) => acc + s.count, 0);
  const [{ count: stalled }, { data: needReply }] = await Promise.all([
    supabase
      .from('leads_master')
      .select('*', { count: 'exact', head: true })
      .not('pipeline_stage', 'in', '(new,converted,lost)')
      .or(`last_contacted_at.lt.${staleCutoff},last_contacted_at.is.null`),
    supabase.rpc('leads_needing_reply', { p_limit: 50 }),
  ]);
  const needReplyCount = (needReply ?? []).length;

  return (
    <div className="p-8">
      <div className="mb-5">
        <h1 className="text-2xl font-semibold text-neutral-900">Pipeline</h1>
        <p className="text-sm text-neutral-500 mt-1">
          Arrastra los leads entre etapas. Se muestran los 25 más recientes por columna.
        </p>
      </div>

      <div className="flex flex-wrap gap-3 mb-5">
        <FunnelStat label="En gestión" value={inFunnel} hint="leads fuera de 'nuevo' que aún no cierran" />
        <FunnelStat
          label="Respondieron sin atender"
          value={needReplyCount}
          hint="leads cuya última interacción fue una respuesta de ellos"
          tone={needReplyCount > 0 ? 'alert' : 'ok'}
        />
        <FunnelStat
          label="Estancados +30 días"
          value={stalled ?? 0}
          hint="en gestión pero sin contacto hace más de 30 días"
          tone={(stalled ?? 0) > 0 ? 'warn' : 'ok'}
        />
        <FunnelStat
          label="Convertidos"
          value={countMap.get('converted') ?? 0}
          hint="leads que llegaron al final del embudo"
        />
      </div>

      <PipelineBoard initialData={stageData} />
    </div>
  );
}

function FunnelStat({ label, value, hint, tone = 'neutral' }: {
  label: string; value: number; hint: string; tone?: 'neutral' | 'alert' | 'warn' | 'ok';
}) {
  const colors: Record<string, string> = {
    neutral: 'text-neutral-900',
    alert:   'text-emerald-700',
    warn:    'text-amber-700',
    ok:      'text-neutral-400',
  };
  return (
    <div className="bg-white border border-neutral-200 rounded-lg px-4 py-3 min-w-[160px]" title={hint}>
      <div className="text-xs text-neutral-500">{label}</div>
      <div className={`text-xl font-semibold mt-0.5 ${colors[tone]}`}>{value.toLocaleString('es-CO')}</div>
    </div>
  );
}
