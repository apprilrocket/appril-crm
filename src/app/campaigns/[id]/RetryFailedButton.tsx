'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { RotateCcw } from 'lucide-react';
import { retryCampaignFailed } from '../actions';

export function RetryFailedButton({ campaignId, failedCount }: { campaignId: string; failedCount: number }) {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<string | null>(null);
  const router = useRouter();

  function onClick() {
    if (!confirm(`¿Reencolar los ${failedCount} mensajes fallidos? El sender los reintentará en el próximo ciclo.`)) return;
    startTransition(async () => {
      const res = await retryCampaignFailed(campaignId);
      if ('error' in res) {
        setResult(`Error: ${res.error}`);
      } else {
        setResult(`✓ ${res.retried} mensajes reencolados`);
        router.refresh();
      }
    });
  }

  return (
    <span className="inline-flex items-center gap-2">
      <button
        onClick={onClick}
        disabled={pending || failedCount === 0}
        className="inline-flex items-center gap-1.5 text-xs bg-white border border-red-300 text-red-700 px-3 py-1.5 rounded-md hover:bg-red-50 disabled:opacity-50 transition-colors"
      >
        <RotateCcw size={12} className={pending ? 'animate-spin' : ''} />
        {pending ? 'Reencolando…' : `Reintentar ${failedCount} fallidos`}
      </button>
      {result && <span className="text-xs text-neutral-500">{result}</span>}
    </span>
  );
}
