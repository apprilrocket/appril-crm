import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { Mail, MessageCircle, Users, Building2 } from 'lucide-react';
import type { ReactNode } from 'react';
import { IntegrationsCard } from './IntegrationsCard';

export const dynamic = 'force-dynamic';

export default async function SettingsPage() {
  const supabase = await createClient();

  const [
    { data: workspace },
    { data: crmUsers },
    { data: { user } },
    { count: totalLeads },
    { count: canEmail },
    { count: canWhatsapp },
    { count: hardBounce },
    { count: unsubscribed },
    { count: activeTemplates },
    { count: activeAutomations },
    { count: pendingQueue },
  ] = await Promise.all([
    supabase.from('workspaces').select('id, name, slug, created_at').limit(1).single(),
    supabase.from('crm_users').select('id, email, role, created_at').order('created_at'),
    supabase.auth.getUser(),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('can_email', true),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('can_whatsapp', true),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('hard_bounce', true),
    supabase.from('leads_master').select('*', { count: 'exact', head: true }).eq('unsubscribed_email', true),
    supabase.from('message_templates').select('*', { count: 'exact', head: true }).eq('status', 'active'),
    supabase.from('automations').select('*', { count: 'exact', head: true }).eq('status', 'active'),
    supabase.from('message_queue').select('*', { count: 'exact', head: true }).in('status', ['pending', 'sending']),
  ]);

  const [{ data: integrations }, { data: me }] = await Promise.all([
    supabase.from('workspace_integrations').select('channel, status, from_email, from_name, wa_phone_number_id, wa_phone_display'),
    supabase.from('crm_users').select('role').eq('auth_user_id', user?.id ?? '').limit(1).maybeSingle(),
  ]);

  const emailPct = totalLeads ? Math.round(((canEmail ?? 0) / totalLeads) * 100) : 0;
  const waPct = totalLeads ? Math.round(((canWhatsapp ?? 0) / totalLeads) * 100) : 0;

  return (
    <div className="p-8 max-w-4xl">
      <h1 className="text-2xl font-semibold text-neutral-900">Settings</h1>
      <p className="text-sm text-neutral-500 mt-1">Configuración del workspace y salud de la base de contactos.</p>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-6">
        <IntegrationsCard integrations={integrations ?? []} isAdmin={me?.role === 'admin'} />

        <Card title="Workspace" icon={<Building2 size={14} />}>
          <dl className="text-sm space-y-1.5">
            <Row k="Nombre" v={workspace?.name ?? '—'} />
            <Row k="Slug" v={<span className="font-mono text-xs">{workspace?.slug ?? '—'}</span>} />
            <Row k="Creado" v={workspace?.created_at ? new Date(workspace.created_at).toLocaleDateString('es-CO') : '—'} />
          </dl>
        </Card>

        <Card title="Usuarios del CRM" icon={<Users size={14} />}>
          <ul className="text-sm space-y-1.5">
            {(crmUsers ?? []).map(u => (
              <li key={u.id} className="flex justify-between">
                <span className={u.email === user?.email ? 'font-medium text-neutral-900' : 'text-neutral-700'}>
                  {u.email} {u.email === user?.email && <span className="text-xs text-neutral-400">(tú)</span>}
                </span>
                <span className="text-xs text-neutral-500 capitalize">{u.role}</span>
              </li>
            ))}
          </ul>
        </Card>

        <Card title="Canal: Email (SES)" icon={<Mail size={14} />}>
          <dl className="text-sm space-y-1.5">
            <Row k="Leads contactables" v={`${(canEmail ?? 0).toLocaleString('es-CO')} (${emailPct}%)`} />
            <Row k="Hard bounces" v={<span className={hardBounce ? 'text-red-700' : ''}>{(hardBounce ?? 0).toLocaleString('es-CO')}</span>} />
            <Row k="Dados de baja" v={(unsubscribed ?? 0).toLocaleString('es-CO')} />
          </dl>
          <p className="text-xs text-neutral-400 mt-3">
            Los bounces y bajas se marcan automáticamente vía webhook de SES — esos leads no vuelven a recibir email.
          </p>
        </Card>

        <Card title="Canal: WhatsApp (Cloud API)" icon={<MessageCircle size={14} />}>
          <dl className="text-sm space-y-1.5">
            <Row k="Leads contactables" v={`${(canWhatsapp ?? 0).toLocaleString('es-CO')} (${waPct}%)`} />
            <Row k="En cola ahora" v={(pendingQueue ?? 0).toLocaleString('es-CO')} />
          </dl>
          <p className="text-xs text-neutral-400 mt-3">
            Los templates de WhatsApp deben estar aprobados en Meta Business Manager antes de usarse en campañas.
          </p>
        </Card>

        <Card title="Motor de envíos">
          <dl className="text-sm space-y-1.5">
            <Row k="Templates activos" v={<Link href="/templates" className="text-brand-600 hover:underline">{activeTemplates ?? 0}</Link>} />
            <Row k="Automatizaciones activas" v={<Link href="/automations" className="text-brand-600 hover:underline">{activeAutomations ?? 0}</Link>} />
            <Row k="Mensajes en cola" v={(pendingQueue ?? 0).toLocaleString('es-CO')} />
          </dl>
          <p className="text-xs text-neutral-400 mt-3">
            El sender procesa la cola cada 2 minutos. Si un mensaje queda en "pending" mucho tiempo, revisa el Lambda.
          </p>
        </Card>

        <Card title="Sesión">
          <dl className="text-sm space-y-1.5">
            <Row k="Email" v={user?.email ?? '—'} />
            <Row k="Último login" v={user?.last_sign_in_at ? new Date(user.last_sign_in_at).toLocaleString('es-CO') : '—'} />
          </dl>
        </Card>
      </div>
    </div>
  );
}

function Card({ title, icon, children }: { title: string; icon?: ReactNode; children: ReactNode }) {
  return (
    <div className="bg-white border border-neutral-200 rounded-lg p-5">
      <div className="flex items-center gap-1.5 text-xs font-medium text-neutral-500 mb-3">
        {icon} {title}
      </div>
      {children}
    </div>
  );
}

function Row({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-neutral-500">{k}</dt>
      <dd className="text-neutral-900 font-medium text-right">{v}</dd>
    </div>
  );
}
