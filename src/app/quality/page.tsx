import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { ShieldCheck, AlertTriangle } from 'lucide-react';

export const dynamic = 'force-dynamic';

type Summary = {
  total: number;
  sin_email: number;
  sin_telefono: number;
  telefono_invalido: number;
  sin_nombre: number;
  email_duplicado: number;
  telefono_duplicado: number;
};

export default async function QualityPage() {
  const supabase = await createClient();
  const { data } = await supabase.rpc('lead_quality_summary');
  const s: Summary = (Array.isArray(data) ? data[0] : data) ?? {
    total: 0, sin_email: 0, sin_telefono: 0, telefono_invalido: 0, sin_nombre: 0, email_duplicado: 0, telefono_duplicado: 0,
  };

  const waListos = Number(s.total) - Number(s.sin_telefono) - Number(s.telefono_invalido);

  const cards = [
    { label: 'Teléfono inválido (no E.164)', value: s.telefono_invalido, href: '/leads?quality=bad_phone', critical: true,
      hint: 'Tienen algo en el campo teléfono pero sin indicativo +XX o mal formado. Excluidos de WhatsApp.' },
    { label: 'Sin teléfono', value: s.sin_telefono, href: '/leads?quality=no_phone',
      hint: 'Solo alcanzables por email.' },
    { label: 'Sin email', value: s.sin_email, href: '/leads?quality=no_email',
      hint: 'Solo alcanzables por WhatsApp (si el teléfono es válido).' },
    { label: 'Sin nombre', value: s.sin_nombre, href: '/leads?quality=no_name',
      hint: 'La personalización {{full_name}} saldrá vacía o genérica.' },
    { label: 'Email duplicado', value: s.email_duplicado, href: null,
      hint: 'Mismo email en más de un lead. Riesgo de contactar dos veces.' },
    { label: 'Teléfono duplicado', value: s.telefono_duplicado, href: null,
      hint: 'Mismo teléfono en más de un lead.' },
  ];

  return (
    <div className="p-8 max-w-5xl">
      <div className="mb-6">
        <h1 className="text-2xl font-semibold text-neutral-900 flex items-center gap-2">
          <ShieldCheck size={24} /> Calidad de datos
        </h1>
        <p className="text-sm text-neutral-500 mt-1">
          {Number(s.total).toLocaleString('es-CO')} leads en total ·{' '}
          <strong className="text-emerald-700">{waListos.toLocaleString('es-CO')} listos para WhatsApp</strong> (teléfono E.164 válido).
          Las campañas excluyen automáticamente lo que aparece aquí.
        </p>
      </div>

      <div className="grid grid-cols-2 lg:grid-cols-3 gap-4">
        {cards.map(c => {
          const inner = (
            <div className={`bg-white border rounded-lg p-5 h-full transition-colors ${
              c.critical && Number(c.value) > 0 ? 'border-red-200 hover:border-red-300' : 'border-neutral-200 hover:border-neutral-300'
            } ${c.href ? 'cursor-pointer' : ''}`}>
              <div className={`text-2xl font-semibold ${c.critical && Number(c.value) > 0 ? 'text-red-600' : 'text-neutral-900'}`}>
                {Number(c.value).toLocaleString('es-CO')}
              </div>
              <div className="text-sm font-medium text-neutral-800 mt-1 flex items-center gap-1.5">
                {c.critical && Number(c.value) > 0 && <AlertTriangle size={13} className="text-red-500" />}
                {c.label}
              </div>
              <p className="text-xs text-neutral-500 mt-1.5 leading-relaxed">{c.hint}</p>
              {c.href && <p className="text-xs text-brand-600 mt-2">Ver y corregir →</p>}
            </div>
          );
          return c.href
            ? <Link key={c.label} href={c.href}>{inner}</Link>
            : <div key={c.label}>{inner}</div>;
        })}
      </div>

      <div className="mt-8 bg-white border border-neutral-200 rounded-lg p-5">
        <h2 className="font-medium text-neutral-900 mb-2">Reglas que protegen tu número de WhatsApp</h2>
        <ul className="text-sm text-neutral-600 space-y-1.5 list-disc pl-5">
          <li>Las campañas de WhatsApp solo encolan leads con teléfono <strong>E.164 válido</strong> (+indicativo) y <code className="text-xs bg-neutral-100 px-1 rounded">can_whatsapp</code> activo. El resto queda excluido y reportado.</li>
          <li>El opt-in se exige por defecto; incluir leads sin opt-in registrado es una decisión explícita por campaña.</li>
          <li>Cuando un lead escribe al número, queda con opt-in automático. Si pide no recibir más mensajes, queda excluido de WhatsApp permanentemente.</li>
          <li>Los imports nunca adivinan el país: teléfono sin indicativo se descarta y se reporta.</li>
        </ul>
      </div>
    </div>
  );
}
