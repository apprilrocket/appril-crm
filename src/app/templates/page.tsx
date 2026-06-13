import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { Plus, Mail, MessageCircle, Pencil } from 'lucide-react';

export const dynamic = 'force-dynamic';

type Template = {
  id: string;
  template_key: string;
  name: string;
  channel: string;
  status: string;
  wa_template_name: string | null;
  subject: string | null;
  text_body: string | null;
  updated_at: string;
};

type Usage = { template_key: string; total: number; sent: number; failed: number; last_used_at: string | null };

export default async function TemplatesPage() {
  const supabase = await createClient();
  const [{ data: templates }, { data: usageRows }] = await Promise.all([
    supabase
      .from('message_templates')
      .select('id, template_key, name, channel, status, wa_template_name, subject, text_body, updated_at')
      .order('channel')
      .order('name'),
    supabase.rpc('template_usage'),
  ]);

  const usage = new Map<string, Usage>(((usageRows ?? []) as Usage[]).map(u => [u.template_key, u]));
  const email = (templates ?? []).filter(t => t.channel === 'email');
  const wa = (templates ?? []).filter(t => t.channel === 'whatsapp');

  return (
    <div className="p-8 max-w-5xl">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-neutral-900">Templates</h1>
          <p className="text-sm text-neutral-500 mt-1">
            Plantillas de email y WhatsApp para campañas y envíos manuales.
          </p>
        </div>
        <Link
          href="/templates/new"
          className="inline-flex items-center gap-2 bg-neutral-900 text-white text-sm px-4 py-2 rounded-md hover:bg-neutral-800 transition-colors"
        >
          <Plus size={15} /> Nuevo template
        </Link>
      </div>

      <TemplateGroup
        title="Email"
        icon={<Mail size={14} />}
        templates={email}
        usage={usage}
        emptyText="No hay templates de email."
      />

      <TemplateGroup
        title="WhatsApp"
        icon={<MessageCircle size={14} />}
        templates={wa}
        usage={usage}
        emptyText="No hay templates de WhatsApp."
        className="mt-6"
      />
    </div>
  );
}

function TemplateGroup({
  title,
  icon,
  templates,
  usage,
  emptyText,
  className = '',
}: {
  title: string;
  icon: React.ReactNode;
  templates: Template[];
  usage: Map<string, Usage>;
  emptyText: string;
  className?: string;
}) {
  return (
    <section className={`bg-white border border-neutral-200 rounded-lg overflow-hidden ${className}`}>
      <div className="flex items-center gap-2 px-5 py-3 border-b border-neutral-100 bg-neutral-50">
        <span className="text-neutral-500">{icon}</span>
        <span className="text-sm font-medium text-neutral-700">{title}</span>
        <span className="ml-auto text-xs text-neutral-400">{templates.length}</span>
      </div>

      {templates.length === 0 ? (
        <p className="px-5 py-8 text-sm text-neutral-400 text-center">{emptyText}</p>
      ) : (
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-neutral-100">
              <th className="text-left px-5 py-2.5 text-xs text-neutral-400 font-medium">Nombre</th>
              <th className="text-left px-4 py-2.5 text-xs text-neutral-400 font-medium hidden md:table-cell">
                {title === 'Email' ? 'Asunto' : 'Template Meta'}
              </th>
              <th className="text-left px-4 py-2.5 text-xs text-neutral-400 font-medium">Estado</th>
              <th className="text-left px-4 py-2.5 text-xs text-neutral-400 font-medium hidden sm:table-cell">Uso</th>
              <th className="text-left px-4 py-2.5 text-xs text-neutral-400 font-medium hidden lg:table-cell">Últ. uso</th>
              <th className="px-4 py-2.5" />
            </tr>
          </thead>
          <tbody className="divide-y divide-neutral-50">
            {templates.map(t => {
              const u = usage.get(t.template_key);
              return (
              <tr key={t.id} className="hover:bg-neutral-50 transition-colors align-top">
                <td className="px-5 py-3">
                  <div className="font-medium text-neutral-900">{t.name}</div>
                  <div className="text-xs text-neutral-400 font-mono">{t.template_key}</div>
                  {t.text_body && (
                    <details className="mt-1">
                      <summary className="text-xs text-brand-600 cursor-pointer hover:underline">Ver contenido</summary>
                      <pre className="mt-1 text-xs text-neutral-600 whitespace-pre-wrap font-sans bg-neutral-50 border border-neutral-100 rounded p-2 max-w-md max-h-48 overflow-auto">
                        {t.text_body}
                      </pre>
                    </details>
                  )}
                </td>
                <td className="px-4 py-3 text-neutral-600 hidden md:table-cell">
                  <span className="truncate block max-w-xs">
                    {title === 'Email' ? (t.subject ?? '—') : (t.wa_template_name ?? '—')}
                  </span>
                </td>
                <td className="px-4 py-3">
                  <StatusBadge status={t.status} />
                </td>
                <td className="px-4 py-3 text-xs hidden sm:table-cell">
                  {u && Number(u.total) > 0 ? (
                    <div>
                      <div className="text-neutral-700 font-medium">{u.total} envíos</div>
                      {Number(u.failed) > 0 && <div className="text-red-600">{u.failed} fallidos</div>}
                    </div>
                  ) : (
                    <span className="text-neutral-300">sin usar</span>
                  )}
                </td>
                <td className="px-4 py-3 text-neutral-400 text-xs hidden lg:table-cell">
                  {u?.last_used_at ? new Date(u.last_used_at).toLocaleDateString('es-CO') : '—'}
                </td>
                <td className="px-4 py-3 text-right">
                  <Link
                    href={`/templates/${t.id}`}
                    className="inline-flex items-center gap-1 text-xs text-neutral-500 hover:text-neutral-900 px-2 py-1 rounded hover:bg-neutral-100"
                  >
                    <Pencil size={12} /> Editar
                  </Link>
                </td>
              </tr>
            );})}
          </tbody>
        </table>
      )}
    </section>
  );
}

function StatusBadge({ status }: { status: string }) {
  const styles: Record<string, string> = {
    active: 'bg-emerald-50 text-emerald-700',
    draft:  'bg-neutral-100 text-neutral-600',
  };
  const labels: Record<string, string> = { active: 'Activo', draft: 'Borrador' };
  return (
    <span className={`inline-block text-xs px-2 py-0.5 rounded-full font-medium ${styles[status] ?? 'bg-neutral-100 text-neutral-600'}`}>
      {labels[status] ?? status}
    </span>
  );
}
