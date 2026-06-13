'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { launchCampaign } from '../actions';
import { Rocket, AlertTriangle } from 'lucide-react';

export function LaunchButton({
  campaignId,
  estimatedLeads,
  channel,
}: {
  campaignId: string;
  estimatedLeads: number;
  channel: string;
}) {
  const router = useRouter();
  const [step, setStep] = useState<'idle' | 'confirm'>('idle');
  const [result, setResult] = useState<string | null>(null);
  const [isError, setIsError] = useState(false);
  const [isPending, startTransition] = useTransition();

  function handleLaunch() {
    startTransition(async () => {
      const res = await launchCampaign(campaignId);
      if ('error' in res) {
        setResult(`Error: ${res.error}`);
        setIsError(true);
      } else {
        setResult(`✅ ${res.queued.toLocaleString('es-CO')} mensajes encolados. El sender los procesará en los próximos minutos.`);
        setIsError(false);
        router.refresh();
      }
      setStep('idle');
    });
  }

  if (result) {
    return (
      <div className={`rounded-lg px-4 py-3 text-sm ${
        isError
          ? 'bg-red-50 border border-red-200 text-red-700'
          : 'bg-emerald-50 border border-emerald-200 text-emerald-700'
      }`}>
        {result}
      </div>
    );
  }

  if (step === 'confirm') {
    return (
      <div className="bg-amber-50 border border-amber-200 rounded-lg p-4">
        <div className="flex items-start gap-3 mb-4">
          <AlertTriangle className="text-amber-600 mt-0.5 shrink-0" size={18} />
          <div>
            <p className="text-sm font-medium text-amber-900">¿Confirmas el lanzamiento?</p>
            <p className="text-sm text-amber-700 mt-1">
              Se encolarán mensajes de <strong>{channel === 'email' ? 'email' : 'WhatsApp'}</strong> para{' '}
              <strong>~{estimatedLeads.toLocaleString('es-CO')} leads</strong>. Esta acción no se puede revertir fácilmente.
            </p>
          </div>
        </div>
        <div className="flex gap-2">
          <button
            onClick={handleLaunch}
            disabled={isPending}
            className="flex items-center gap-2 px-4 py-2 bg-amber-600 text-white text-sm font-medium rounded-md hover:bg-amber-700 disabled:opacity-50"
          >
            <Rocket size={14} />
            {isPending ? 'Lanzando…' : 'Sí, lanzar ahora'}
          </button>
          <button
            type="button"
            onClick={() => setStep('idle')}
            disabled={isPending}
            className="px-4 py-2 text-sm text-neutral-600 border border-neutral-200 rounded-md hover:bg-neutral-50"
          >
            Cancelar
          </button>
        </div>
      </div>
    );
  }

  return (
    <button
      onClick={() => setStep('confirm')}
      className="inline-flex items-center gap-2 px-5 py-2.5 bg-brand-600 text-white text-sm font-medium rounded-md hover:bg-brand-700 transition-colors"
    >
      <Rocket size={15} /> Lanzar campaña
    </button>
  );
}
