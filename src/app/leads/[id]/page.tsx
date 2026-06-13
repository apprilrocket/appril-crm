import { createClient } from '@/lib/supabase/server';
import { notFound } from 'next/navigation';
import Link from 'next/link';
import { SegmentBadge, StageBadge, HeatBadge, HeatBar } from '@/components/SegmentBadge';
import { ArrowLeft, Mail, Phone, MapPin } from 'lucide-react';
import { formatDate, relativeTime } from '@/lib/utils';
import { nextActionForLead, ACTION_TONE_CLASSES } from '@/lib/nextAction';
import { LeadActions } from './LeadActions';
import { TasksCard } from './TasksCard';
import { Timeline } from './Timeline';

export const dynamic = 'force-dynamic';

export default async function LeadDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: lead } = await supabase
    .from('leads_master')
    .select('*')
    .eq('id', id)
    .single();

  if (!lead) notFound();

  const [{ data: events }, { data: notes }, { data: tasks }, { data: runs }, { data: templates }, { data: stages }] = await Promise.all([
    supabase.from('lead_events').select('*').eq('lead_id', id).order('created_at', { ascending: false }).limit(30),
    supabase.from('lead_notes').select('*').eq('lead_id', id).order('created_at', { ascending: false }).limit(10),
    supabase.from('lead_tasks').select('*').eq('lead_id', id).order('due_at').limit(10),
    supabase.from('automation_runs').select('id, status, current_node_id, started_at, automation_id, automations(name)').eq('lead_id', id),
    supabase.from('message_templates').select('template_key, name, channel').eq('status', 'active'),
    supabase.from('pipeline_stages').select('key, label, color').order('position')
  ]);

  // Próxima acción recomendada según el historial real del lead
  const evs = events ?? [];
  const lastSent = evs.find(e => ['message_sent', 'wa_agent_reply'].includes(e.event_type));
  const lastReply = evs.find(e => ['wa_reply', 'email_replied', 'contact_submitted', 'discovery_form_submitted'].includes(e.event_type));
  const lastOpen = evs.find(e => ['email_opened', 'email_clicked', 'cta_clicked', 'wa_read'].includes(e.event_type));
  const action = nextActionForLead({
    email: lead.email,
    phone: lead.phone,
    engagement_score: lead.engagement_score,
    last_engaged_at: lead.last_engaged_at,
    last_contacted_at: lead.last_contacted_at,
    pipeline_stage: lead.pipeline_stage,
    lastSentAt: lastSent?.created_at ?? null,
    lastReplyAt: lastReply?.created_at ?? null,
    lastReplyValue: lastReply?.event_value ?? null,
    lastOpenAt: lastOpen?.created_at ?? null,
  });

  return (
    <div className="p-8 max-w-6xl">
      <Link href="/leads" className="text-sm text-neutral-500 hover:text-neutral-900 inline-flex items-center gap-1 mb-4">
        <ArrowLeft size={14} /> Volver a leads
      </Link>

      <div className="flex items-start justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-neutral-900">
            {lead.full_name ?? <span className="text-neutral-400 italic">Sin nombre</span>}
          </h1>
          <div className="flex items-center gap-3 mt-2 text-sm text-neutral-600">
            {lead.email && <span className="inline-flex items-center gap-1"><Mail size={14} />{lead.email}</span>}
            {lead.phone && <span className="inline-flex items-center gap-1"><Phone size={14} />{lead.phone}</span>}
            {lead.city  && <span className="inline-flex items-center gap-1"><MapPin size={14} />{lead.city}</span>}
          </div>
          <div className="flex items-center gap-2 mt-3">
            <SegmentBadge segment={lead.marketing_segment} />
            {(() => {
              const st = (stages ?? []).find(s => s.key === (lead.pipeline_stage ?? 'new'));
              return <StageBadge stage={st?.label ?? lead.pipeline_stage ?? 'new'} color={st?.color} />;
            })()}
            <HeatBadge score={lead.engagement_score} lastEngagedAt={lead.last_engaged_at} />
            <span className="text-xs text-neutral-500">fuente: <strong>{lead.source ?? '—'}</strong></span>
          </div>
        </div>
      </div>

      {action && (
        <div className={`border rounded-lg px-4 py-3 mb-4 ${ACTION_TONE_CLASSES[action.tone]}`}>
          <div className="text-sm font-semibold">Próxima acción: {action.text}</div>
          {action.detail && <div className="text-xs mt-0.5 opacity-80">{action.detail}</div>}
        </div>
      )}

      <LeadActions
        leadId={lead.id}
        currentStage={lead.pipeline_stage ?? 'new'}
        stages={stages ?? []}
        templates={templates ?? []}
        canEmail={lead.can_email ?? false}
        canWhatsapp={lead.can_whatsapp ?? false}
        email={lead.email}
        phone={lead.phone}
      />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 mt-8">
        <section className="lg:col-span-2 bg-white border border-neutral-200 rounded-lg p-5">
          <h2 className="text-sm font-semibold text-neutral-900 mb-4">Timeline</h2>
          <Timeline events={evs} />
        </section>

        <aside className="space-y-6">
          <section className="bg-white border border-neutral-200 rounded-lg p-5">
            <h2 className="text-sm font-semibold text-neutral-900 mb-2">Datos clave</h2>
            <div className="mb-3">
              <HeatBar score={lead.engagement_score} lastEngagedAt={lead.last_engaged_at} />
            </div>
            <dl className="text-sm space-y-1.5">
              <Row k="Últ. engagement" v={lead.last_engaged_at ? relativeTime(lead.last_engaged_at) : 'nunca'} />
              <Row k="Total citas"    v={lead.total_citas ?? 0} />
              <Row k="Última cita"    v={formatDate(lead.ultima_cita)} />
              <Row k="Total pacientes" v={lead.total_pacientes ?? 0} />
              <Row k="Pagando hoy"    v={lead.pagando_hoy ? 'Sí' : 'No'} />
              <Row k="Alguna vez pagó" v={lead.alguna_vez_pago ? 'Sí' : 'No'} />
              <Row k="Recovery score" v={lead.recovery_score ?? '—'} />
              <Row k="Especialidad"   v={lead.specialization ?? '—'} />
            </dl>
          </section>

          <section className="bg-white border border-neutral-200 rounded-lg p-5">
            <h2 className="text-sm font-semibold text-neutral-900 mb-2">Automatizaciones activas</h2>
            {runs && runs.length > 0 ? (
              <ul className="text-sm space-y-1.5">
                {runs.map(r => (
                  <li key={r.id} className="flex justify-between">
                    <span>{(r.automations as any)?.name ?? r.automation_id}</span>
                    <span className="text-xs text-neutral-500">
                      {r.status === 'converted' ? '🏆 convertido' : r.status === 'active' ? `en curso · ${relativeTime(r.started_at)}` : r.status}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-neutral-500">Ninguna.</p>
            )}
          </section>

          <section className="bg-white border border-neutral-200 rounded-lg p-5">
            <h2 className="text-sm font-semibold text-neutral-900 mb-2">Notas</h2>
            {notes && notes.length > 0 ? (
              <ul className="text-sm space-y-2">
                {notes.map(n => (
                  <li key={n.id} className="border-l-2 border-neutral-200 pl-2">
                    <div className="text-neutral-800">{n.body}</div>
                    <div className="text-xs text-neutral-400">{relativeTime(n.created_at)}</div>
                  </li>
                ))}
              </ul>
            ) : <p className="text-sm text-neutral-500">Sin notas.</p>}
          </section>

          <TasksCard leadId={lead.id} tasks={tasks ?? []} />
        </aside>
      </div>
    </div>
  );
}

function Row({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div className="flex justify-between text-sm">
      <dt className="text-neutral-500">{k}</dt>
      <dd className="text-neutral-900 font-medium">{v as any}</dd>
    </div>
  );
}
