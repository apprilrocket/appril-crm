'use client';

import { useFormState, useFormStatus } from 'react-dom';
import { createLead, type CreateLeadState } from '../actions';

const SEGMENTS = ['SUPER_HOT', 'HOT', 'WARM', 'COLD'];

export function NewLeadForm({ stages }: { stages: { key: string; label: string }[] }) {
  const [state, formAction] = useFormState<CreateLeadState, FormData>(createLead, null);

  return (
    <form action={formAction} className="mt-6 bg-white border border-neutral-200 rounded-lg p-6 space-y-4">
      <Field label="Nombre completo *">
        <input name="full_name" required placeholder="Dra. Ana Pérez" className={inputCls} />
      </Field>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Field label="Email">
          <input name="email" type="email" placeholder="ana@clinica.co" className={inputCls} />
        </Field>
        <Field label="Teléfono (WhatsApp)">
          <input name="phone" placeholder="+57 300 123 4567" className={inputCls} />
        </Field>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Field label="Ciudad">
          <input name="city" placeholder="Bogotá" className={inputCls} />
        </Field>
        <Field label="Especialidad">
          <input name="specialization" placeholder="Odontología" className={inputCls} />
        </Field>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <Field label="Fuente">
          <input name="source" defaultValue="manual" className={inputCls} />
        </Field>
        <Field label="Segmento">
          <select name="marketing_segment" defaultValue="WARM" className={inputCls}>
            {SEGMENTS.map(s => <option key={s} value={s}>{s}</option>)}
          </select>
        </Field>
        <Field label="Etapa inicial">
          <select name="pipeline_stage" defaultValue="new" className={inputCls}>
            {stages.map(s => <option key={s.key} value={s.key}>{s.label}</option>)}
          </select>
        </Field>
      </div>

      <Field label="Nota inicial (opcional)">
        <textarea name="note" rows={3} placeholder="Contexto: cómo llegó, qué le interesa…" className={inputCls} />
      </Field>

      {state?.error && (
        <div className="text-sm text-red-600 bg-red-50 border border-red-200 rounded-md p-3">{state.error}</div>
      )}

      <div className="flex justify-end">
        <SubmitButton />
      </div>
    </form>
  );
}

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      disabled={pending}
      className="px-4 py-2 bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white text-sm font-medium rounded-md"
    >
      {pending ? 'Creando…' : 'Crear lead'}
    </button>
  );
}

const inputCls = 'w-full px-3 py-2 text-sm border border-neutral-200 rounded-md bg-white focus:outline-none focus:ring-2 focus:ring-brand-500';

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="text-xs font-medium text-neutral-600">{label}</span>
      <div className="mt-1">{children}</div>
    </label>
  );
}
