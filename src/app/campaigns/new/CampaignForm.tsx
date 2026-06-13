'use client';

import { useState, useTransition, useEffect, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { createCampaign, countCampaignLeads } from '../actions';
import { Users } from 'lucide-react';

type Template = { template_key: string; name: string; channel: string };
type ListOption = { id: string; name: string; members: number };

const SEGMENTS = [
  { value: 'SUPER_HOT', label: 'SUPER HOT',  desc: 'Pagando o muy comprometidos',    color: 'text-red-700 border-red-200 bg-red-50' },
  { value: 'HOT',       label: 'HOT',         desc: 'Ex-pagadores, recovery alto',    color: 'text-orange-700 border-orange-200 bg-orange-50' },
  { value: 'WARM',      label: 'WARM',        desc: 'Base histórica Todoc',           color: 'text-yellow-700 border-yellow-200 bg-yellow-50' },
  { value: 'COLD',      label: 'COLD',        desc: 'Base fría Colombia',             color: 'text-sky-700 border-sky-200 bg-sky-50' },
];

export function CampaignForm({ templates, lists }: { templates: Template[]; lists: ListOption[] }) {
  const router = useRouter();
  const [channel, setChannel] = useState('email');
  const [selectedSegments, setSelectedSegments] = useState<string[]>([]);
  const [selectedLists, setSelectedLists] = useState<string[]>([]);
  const [allowNoOptin, setAllowNoOptin] = useState(false);
  const [templateKey, setTemplateKey] = useState('');
  const [scheduleNow, setScheduleNow] = useState(true);
  const [scheduledAt, setScheduledAt] = useState('');
  const [leadCount, setLeadCount] = useState<{ count: number; audience: number } | null>(null);
  const [countLoading, setCountLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();

  const hasAudience = selectedSegments.length > 0 || selectedLists.length > 0;

  const filteredTemplates = templates.filter(t => t.channel === channel);

  // Reset template if channel changes and current template doesn't match
  useEffect(() => {
    if (templateKey) {
      const tpl = templates.find(t => t.template_key === templateKey);
      if (tpl && tpl.channel !== channel) setTemplateKey('');
    }
  }, [channel, templateKey, templates]);

  // Recalcula alcance cuando cambian canal, segmentos, listas u opt-in
  useEffect(() => {
    if (selectedSegments.length === 0 && selectedLists.length === 0) { setLeadCount(null); return; }
    const timer = setTimeout(async () => {
      setCountLoading(true);
      const result = await countCampaignLeads(channel, selectedSegments, selectedLists, allowNoOptin);
      setLeadCount('count' in result ? result : null);
      setCountLoading(false);
    }, 400);
    return () => clearTimeout(timer);
  }, [channel, selectedSegments, selectedLists, allowNoOptin]);

  function toggleSegment(seg: string) {
    setSelectedSegments(prev =>
      prev.includes(seg) ? prev.filter(s => s !== seg) : [...prev, seg]
    );
  }

  function toggleList(id: string) {
    setSelectedLists(prev =>
      prev.includes(id) ? prev.filter(l => l !== id) : [...prev, id]
    );
  }

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    const name = fd.get('name') as string;

    if (!name.trim()) { setError('El nombre es requerido.'); return; }
    if (!templateKey) { setError('Selecciona un template.'); return; }
    if (!hasAudience) { setError('Selecciona al menos un segmento o una lista.'); return; }

    setError(null);
    startTransition(async () => {
      const result = await createCampaign({
        name,
        description: (fd.get('description') as string) || undefined,
        channel,
        template_key: templateKey,
        segments: selectedSegments,
        list_ids: selectedLists,
        allow_no_optin: channel === 'whatsapp' ? allowNoOptin : undefined,
        scheduled_at: scheduleNow ? undefined : scheduledAt || undefined,
      });

      if ('error' in result) {
        setError(result.error);
      } else {
        router.push(`/campaigns/${result.id}`);
        router.refresh();
      }
    });
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      {/* Canal */}
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-2">Canal</label>
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
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-1.5">
          Nombre <span className="text-red-500">*</span>
        </label>
        <input
          name="name"
          placeholder="Ej: Reactivación HOT — Junio 2026"
          className="input-base"
        />
      </div>

      {/* Descripción */}
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-1.5">Descripción (opcional)</label>
        <input
          name="description"
          placeholder="Objetivo de esta campaña..."
          className="input-base"
        />
      </div>

      {/* Template */}
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-1.5">
          Template <span className="text-red-500">*</span>
        </label>
        {filteredTemplates.length === 0 ? (
          <div className="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded-md px-3 py-2">
            No hay templates activos para {channel === 'email' ? 'email' : 'WhatsApp'}.{' '}
            <a href="/templates/new" className="underline">Crear uno</a>.
          </div>
        ) : (
          <select
            value={templateKey}
            onChange={e => setTemplateKey(e.target.value)}
            className="input-base bg-white"
          >
            <option value="">— Selecciona un template —</option>
            {filteredTemplates.map(t => (
              <option key={t.template_key} value={t.template_key}>{t.name}</option>
            ))}
          </select>
        )}
      </div>

      {/* Segmentos */}
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-2">
          Audiencia: segmentos {lists.length > 0 && 'y/o listas'} <span className="text-red-500">*</span>
        </label>
        <div className="grid grid-cols-2 gap-2">
          {SEGMENTS.map(s => {
            const selected = selectedSegments.includes(s.value);
            return (
              <button
                key={s.value}
                type="button"
                onClick={() => toggleSegment(s.value)}
                className={`text-left px-3 py-2.5 rounded-md border text-sm transition-colors ${
                  selected
                    ? `border-current ${s.color} font-medium`
                    : 'border-neutral-200 text-neutral-600 hover:bg-neutral-50'
                }`}
              >
                <div className="font-medium">{s.label}</div>
                <div className="text-xs opacity-70 mt-0.5">{s.desc}</div>
              </button>
            );
          })}
        </div>

        {/* Listas */}
        {lists.length > 0 && (
          <div className="flex flex-wrap gap-2 mt-2">
            {lists.map(l => {
              const selected = selectedLists.includes(l.id);
              return (
                <button
                  key={l.id}
                  type="button"
                  onClick={() => toggleList(l.id)}
                  className={`px-3 py-1.5 rounded-md border text-sm transition-colors ${
                    selected
                      ? 'border-brand-500 bg-brand-50 text-brand-700 font-medium'
                      : 'border-neutral-200 text-neutral-600 hover:bg-neutral-50'
                  }`}
                >
                  📋 {l.name} <span className="opacity-60">({l.members.toLocaleString('es-CO')})</span>
                </button>
              );
            })}
          </div>
        )}

        {/* Lead count: elegibles vs audiencia */}
        {hasAudience && (
          <div className={`mt-3 flex items-center gap-2 text-sm ${leadCount !== null ? 'text-neutral-700' : 'text-neutral-400'}`}>
            <Users size={14} />
            {countLoading
              ? 'Calculando alcance…'
              : leadCount !== null
                ? <>
                    <strong>{leadCount.count.toLocaleString('es-CO')}</strong>&nbsp;elegibles de {leadCount.audience.toLocaleString('es-CO')} en la audiencia
                    {leadCount.audience > leadCount.count && (
                      <span className="text-xs text-amber-700">
                        ({(leadCount.audience - leadCount.count).toLocaleString('es-CO')} excluidos por {channel === 'email' ? 'email inválido o bloqueado' : `teléfono no E.164, WhatsApp bloqueado${!allowNoOptin ? ' o sin opt-in' : ''}`})
                      </span>
                    )}
                  </>
                : '—'
            }
          </div>
        )}

        {/* Override de opt-in (solo WhatsApp) */}
        {channel === 'whatsapp' && hasAudience && (
          <label className="mt-3 flex items-start gap-2 text-xs text-neutral-600 bg-amber-50/60 border border-amber-200 rounded-md px-3 py-2.5 cursor-pointer">
            <input
              type="checkbox"
              checked={allowNoOptin}
              onChange={e => setAllowNoOptin(e.target.checked)}
              className="accent-amber-600 mt-0.5"
            />
            <span>
              <strong>Incluir leads sin opt-in registrado.</strong> Meta exige consentimiento para mensajes de marketing;
              enviar sin opt-in aumenta blocks y puede degradar el quality rating de tu número. Úsalo con volúmenes pequeños y templates de alto valor.
            </span>
          </label>
        )}
      </div>

      {/* Programación */}
      <div>
        <label className="block text-xs font-medium text-neutral-500 mb-2">Envío</label>
        <div className="flex gap-2 mb-2">
          <button
            type="button"
            onClick={() => setScheduleNow(true)}
            className={`px-4 py-2 text-sm rounded-md border transition-colors ${
              scheduleNow
                ? 'border-brand-500 bg-brand-50 text-brand-700 font-medium'
                : 'border-neutral-200 text-neutral-600 hover:bg-neutral-50'
            }`}
          >
            Al lanzar
          </button>
          <button
            type="button"
            onClick={() => setScheduleNow(false)}
            className={`px-4 py-2 text-sm rounded-md border transition-colors ${
              !scheduleNow
                ? 'border-brand-500 bg-brand-50 text-brand-700 font-medium'
                : 'border-neutral-200 text-neutral-600 hover:bg-neutral-50'
            }`}
          >
            Programar
          </button>
        </div>
        {!scheduleNow && (
          <input
            type="datetime-local"
            value={scheduledAt}
            onChange={e => setScheduledAt(e.target.value)}
            className="input-base"
          />
        )}
        <p className="text-xs text-neutral-400 mt-1">
          {scheduleNow
            ? 'Los mensajes se encolarán cuando hagas clic en "Lanzar" en la próxima pantalla.'
            : 'El Sender Lambda los enviará cuando llegue la hora programada.'}
        </p>
      </div>

      {error && (
        <div className="bg-red-50 border border-red-200 text-red-700 text-sm rounded-md px-4 py-3">
          {error}
        </div>
      )}

      <div className="flex justify-between border-t border-neutral-100 pt-5">
        <button
          type="button"
          onClick={() => router.push('/campaigns')}
          className="px-4 py-2 text-sm text-neutral-600 border border-neutral-200 rounded-md hover:bg-neutral-50"
        >
          Cancelar
        </button>
        <button
          type="submit"
          disabled={isPending}
          className="px-5 py-2 text-sm bg-neutral-900 text-white rounded-md hover:bg-neutral-800 disabled:opacity-50 font-medium"
        >
          {isPending ? 'Creando…' : 'Crear campaña →'}
        </button>
      </div>
    </form>
  );
}
