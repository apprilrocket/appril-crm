'use client';

import { useState, useTransition, type ReactNode, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { saveTemplate, deleteTemplate } from '../actions';
import { Trash2 } from 'lucide-react';

type Template = {
  id: string;
  template_key: string;
  name: string;
  channel: string;
  status: string;
  subject: string | null;
  html_body: string | null;
  text_body: string | null;
  wa_template_name: string | null;
  wa_language: string | null;
} | null;

const VARIABLES_HINT = '{{full_name}}, {{email}}, {{phone}}';

export function TemplateForm({ template }: { template: Template }) {
  const router = useRouter();
  const [channel, setChannel] = useState(template?.channel ?? 'email');
  const [status, setStatus] = useState(template?.status ?? 'draft');
  const [error, setError] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();
  const [isDeleting, startDelete] = useTransition();
  const [confirmDelete, setConfirmDelete] = useState(false);

  function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);

    const payload = {
      name: fd.get('name') as string,
      channel,
      status,
      subject: (fd.get('subject') as string) || undefined,
      html_body: (fd.get('html_body') as string) || undefined,
      text_body: (fd.get('text_body') as string) || undefined,
      wa_template_name: (fd.get('wa_template_name') as string) || undefined,
      wa_language: (fd.get('wa_language') as string) || 'es',
    };

    if (!payload.name.trim()) {
      setError('El nombre es requerido.');
      return;
    }

    setError(null);
    startTransition(async () => {
      const result = await saveTemplate(template?.id ?? null, payload);
      if ('error' in result) {
        setError(result.error);
      } else {
        router.push('/templates');
        router.refresh();
      }
    });
  }

  function handleDelete() {
    if (!template) return;
    startDelete(async () => {
      const result = await deleteTemplate(template.id);
      if ('error' in result) {
        setError(result.error);
      } else {
        router.push('/templates');
        router.refresh();
      }
    });
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-5">
      {/* Canal */}
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-1.5">Canal</label>
        <div className="flex gap-2">
          {['email', 'whatsapp'].map(c => (
            <button
              key={c}
              type="button"
              onClick={() => setChannel(c)}
              className={`px-4 py-2 text-sm rounded-md border transition-colors ${
                channel === c
                  ? 'border-brand-500 bg-brand-50 text-brand-700 font-medium'
                  : 'border-neutral-200 text-neutral-600 hover:bg-neutral-50'
              }`}
            >
              {c === 'email' ? '✉ Email' : '💬 WhatsApp'}
            </button>
          ))}
        </div>
      </div>

      {/* Nombre */}
      <Field label="Nombre del template" required>
        <input
          name="name"
          defaultValue={template?.name ?? ''}
          placeholder="Ej: Reactivación HOT — Mayo 2026"
          className="input-base"
        />
      </Field>

      {/* Estado */}
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-1.5">Estado</label>
        <div className="flex gap-2">
          {[
            { value: 'draft', label: 'Borrador' },
            { value: 'active', label: 'Activo' },
          ].map(s => (
            <button
              key={s.value}
              type="button"
              onClick={() => setStatus(s.value)}
              className={`px-4 py-2 text-sm rounded-md border transition-colors ${
                status === s.value
                  ? 'border-brand-500 bg-brand-50 text-brand-700 font-medium'
                  : 'border-neutral-200 text-neutral-600 hover:bg-neutral-50'
              }`}
            >
              {s.label}
            </button>
          ))}
        </div>
        {status === 'active' && (
          <p className="text-xs text-neutral-400 mt-1">
            Solo los templates activos aparecen en campañas y envío manual.
          </p>
        )}
      </div>

      {/* Campos de Email */}
      {channel === 'email' && (
        <div className="space-y-4 border-t border-neutral-100 pt-5">
          <p className="text-xs text-neutral-400">Variables disponibles: <code className="bg-neutral-100 px-1 rounded">{VARIABLES_HINT}</code></p>

          <Field label="Asunto">
            <input
              name="subject"
              defaultValue={template?.subject ?? ''}
              placeholder="Hola {{full_name}} — algo que puede ayudarte"
              className="input-base"
            />
          </Field>

          <Field label="Cuerpo HTML" hint="HTML completo del email. Usa {{variable}} para personalizar.">
            <textarea
              name="html_body"
              defaultValue={template?.html_body ?? ''}
              placeholder={'<html>\n<body>\n  <p>Hola {{full_name}},</p>\n</body>\n</html>'}
              rows={14}
              className="input-base font-mono text-xs resize-y"
            />
          </Field>

          <Field label="Cuerpo texto plano" hint="Versión texto del email (fallback para clientes que no renderan HTML).">
            <textarea
              name="text_body"
              defaultValue={template?.text_body ?? ''}
              placeholder={'Hola {{full_name}},\n\n...'}
              rows={6}
              className="input-base font-mono text-xs resize-y"
            />
          </Field>
        </div>
      )}

      {/* Campos de WhatsApp */}
      {channel === 'whatsapp' && (
        <div className="space-y-4 border-t border-neutral-100 pt-5">
          <div className="bg-amber-50 border border-amber-200 rounded-md p-3 text-xs text-amber-800">
            Los templates de WhatsApp deben estar aprobados en Meta Business Manager antes de poder enviarse.
            El nombre aquí debe coincidir exactamente con el nombre en Meta.
          </div>

          <Field label="Nombre del template en Meta" required hint="Exactamente como aparece en WhatsApp Manager (ej: appril_c5_recuperar_valioso)">
            <input
              name="wa_template_name"
              defaultValue={template?.wa_template_name ?? ''}
              placeholder="appril_nombre_template"
              className="input-base font-mono"
            />
          </Field>

          <Field label="Idioma" hint="Código de idioma del template en Meta.">
            <select name="wa_language" defaultValue={template?.wa_language ?? 'es'} className="input-base bg-white">
              <option value="es">es — Español</option>
              <option value="en_US">en_US — English (US)</option>
              <option value="pt_BR">pt_BR — Português (Brasil)</option>
            </select>
          </Field>

          <Field label="Cuerpo (referencia)" hint="Copia aquí el contenido del template para referencia. Use {{full_name}} para la primera variable.">
            <textarea
              name="text_body"
              defaultValue={template?.text_body ?? ''}
              placeholder={'Hola {{full_name}}, soy Mauricio 👋\n\n...'}
              rows={6}
              className="input-base text-xs resize-y"
            />
          </Field>
        </div>
      )}

      {error && (
        <div className="bg-red-50 border border-red-200 text-red-700 text-sm rounded-md px-4 py-3">
          {error}
        </div>
      )}

      {/* Acciones */}
      <div className="flex items-center justify-between border-t border-neutral-100 pt-5">
        <div>
          {template && !confirmDelete && (
            <button
              type="button"
              onClick={() => setConfirmDelete(true)}
              className="inline-flex items-center gap-1.5 text-xs text-red-600 hover:text-red-700 px-3 py-2 rounded hover:bg-red-50"
            >
              <Trash2 size={13} /> Eliminar
            </button>
          )}
          {template && confirmDelete && (
            <div className="flex items-center gap-2">
              <span className="text-xs text-neutral-600">¿Seguro?</span>
              <button
                type="button"
                onClick={handleDelete}
                disabled={isDeleting}
                className="text-xs text-red-600 hover:text-red-700 px-3 py-1.5 rounded border border-red-200 hover:bg-red-50"
              >
                {isDeleting ? 'Eliminando…' : 'Sí, eliminar'}
              </button>
              <button
                type="button"
                onClick={() => setConfirmDelete(false)}
                className="text-xs text-neutral-500 hover:text-neutral-700 px-3 py-1.5 rounded border border-neutral-200"
              >
                Cancelar
              </button>
            </div>
          )}
        </div>

        <div className="flex items-center gap-3">
          <button
            type="button"
            onClick={() => router.push('/templates')}
            className="px-4 py-2 text-sm text-neutral-600 hover:text-neutral-900 border border-neutral-200 rounded-md"
          >
            Cancelar
          </button>
          <button
            type="submit"
            disabled={isPending}
            className="px-5 py-2 text-sm bg-neutral-900 text-white rounded-md hover:bg-neutral-800 disabled:opacity-50 font-medium"
          >
            {isPending ? 'Guardando…' : template ? 'Guardar cambios' : 'Crear template'}
          </button>
        </div>
      </div>
    </form>
  );
}

function Field({
  label,
  required,
  hint,
  children,
}: {
  label: string;
  required?: boolean;
  hint?: string;
  children: ReactNode;
}) {
  return (
    <div>
      <label className="block text-xs font-medium text-neutral-500 mb-1.5">
        {label}
        {required && <span className="text-red-500 ml-0.5">*</span>}
      </label>
      {children}
      {hint && <p className="text-xs text-neutral-400 mt-1">{hint}</p>}
    </div>
  );
}
