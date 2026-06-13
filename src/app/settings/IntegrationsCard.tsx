'use client';

import { useState, useTransition } from 'react';
import { updateEmailIntegration } from './actions';

type Integration = {
  channel: string;
  status: string;
  from_email: string | null;
  from_name: string | null;
  wa_phone_number_id: string | null;
  wa_phone_display: string | null;
};

const STATUS_LABEL: Record<string, { label: string; cls: string }> = {
  unconfigured: { label: 'Sin configurar', cls: 'bg-neutral-100 text-neutral-600' },
  pending_verification: { label: 'Pendiente de verificación', cls: 'bg-amber-50 text-amber-700' },
  active: { label: 'Activo', cls: 'bg-emerald-50 text-emerald-700' },
  disabled: { label: 'Deshabilitado', cls: 'bg-red-50 text-red-700' }
};

function StatusBadge({ status }: { status: string }) {
  const s = STATUS_LABEL[status] ?? STATUS_LABEL.unconfigured;
  return <span className={`text-[11px] font-medium px-2 py-0.5 rounded-full ${s.cls}`}>{s.label}</span>;
}

export function IntegrationsCard({ integrations, isAdmin }: { integrations: Integration[]; isAdmin: boolean }) {
  const email = integrations.find(i => i.channel === 'email');
  const wa = integrations.find(i => i.channel === 'whatsapp');

  const [fromEmail, setFromEmail] = useState(email?.from_email ?? '');
  const [fromName, setFromName] = useState(email?.from_name ?? '');
  const [msg, setMsg] = useState<{ ok?: boolean; text: string } | null>(null);
  const [pending, startTransition] = useTransition();

  function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    const fd = new FormData();
    fd.set('from_email', fromEmail);
    fd.set('from_name', fromName);
    startTransition(async () => {
      const res = await updateEmailIntegration(fd);
      if (res?.error) setMsg({ text: res.error });
      else setMsg({ ok: true, text: 'Guardado. El dominio debe verificarse (DKIM/SPF) antes de activar el envío.' });
    });
  }

  return (
    <div className="bg-white border border-neutral-200 rounded-lg p-5 md:col-span-2">
      <div className="text-xs font-medium text-neutral-500 mb-3">Integraciones de envío</div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Email */}
        <div>
          <div className="flex items-center justify-between mb-2">
            <span className="text-sm font-medium text-neutral-900">Email (remitente)</span>
            <StatusBadge status={email?.status ?? 'unconfigured'} />
          </div>
          {isAdmin ? (
            <form onSubmit={onSubmit} className="space-y-2">
              <input
                type="text"
                placeholder="Nombre del remitente (ej: Mi Empresa)"
                value={fromName}
                onChange={e => setFromName(e.target.value)}
                className="w-full px-3 py-1.5 border border-neutral-300 rounded-md text-sm"
              />
              <input
                type="email"
                required
                placeholder="hola@tudominio.com"
                value={fromEmail}
                onChange={e => setFromEmail(e.target.value)}
                className="w-full px-3 py-1.5 border border-neutral-300 rounded-md text-sm"
              />
              {msg && (
                <div className={`text-xs ${msg.ok ? 'text-emerald-700' : 'text-red-600'}`}>{msg.text}</div>
              )}
              <button
                type="submit"
                disabled={pending}
                className="bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white px-3 py-1.5 rounded-md text-xs font-medium"
              >
                {pending ? 'Guardando…' : 'Guardar remitente'}
              </button>
            </form>
          ) : (
            <p className="text-sm text-neutral-600">{email?.from_email ?? 'Sin configurar'}</p>
          )}
          <p className="text-xs text-neutral-400 mt-2">
            Tras guardar, el dominio del remitente se verifica en el proveedor de envío (registros DNS). Hasta entonces el canal queda pendiente.
          </p>
        </div>

        {/* WhatsApp */}
        <div>
          <div className="flex items-center justify-between mb-2">
            <span className="text-sm font-medium text-neutral-900">WhatsApp Business</span>
            <StatusBadge status={wa?.status ?? 'unconfigured'} />
          </div>
          <dl className="text-sm space-y-1">
            <div className="flex justify-between">
              <dt className="text-neutral-500">Número</dt>
              <dd className="text-neutral-900">{wa?.wa_phone_display ?? (wa?.wa_phone_number_id ? `ID ${wa.wa_phone_number_id}` : '—')}</dd>
            </div>
          </dl>
          <p className="text-xs text-neutral-400 mt-2">
            La conexión de un número de WhatsApp Business se configura con el equipo de soporte (requiere una cuenta de WhatsApp Business API en Meta).
          </p>
        </div>
      </div>
    </div>
  );
}
