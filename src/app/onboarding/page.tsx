'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';

export default function OnboardingPage() {
  const [name, setName] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc('create_workspace_with_admin', { p_name: name });

    if (error) {
      setLoading(false);
      setError(error.message);
      return;
    }
    router.push('/');
    router.refresh();
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-neutral-50 px-4">
      <div className="w-full max-w-sm bg-white border border-neutral-200 rounded-lg p-8">
        <h1 className="text-xl font-semibold text-neutral-900">Crea tu workspace</h1>
        <p className="text-sm text-neutral-500 mt-1">
          Tu cuenta está lista. Dale un nombre a tu espacio de trabajo — normalmente el de tu empresa o equipo.
        </p>

        <form onSubmit={onSubmit} className="mt-6 space-y-3">
          <input
            type="text"
            required
            minLength={2}
            maxLength={60}
            placeholder="Mi empresa"
            value={name}
            onChange={e => setName(e.target.value)}
            className="w-full px-3 py-2 border border-neutral-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-brand-500 focus:border-transparent"
          />
          {error && <div className="text-xs text-red-600">{error}</div>}
          <button
            type="submit"
            disabled={loading}
            className="w-full bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white py-2 rounded-md text-sm font-medium transition-colors"
          >
            {loading ? 'Creando…' : 'Crear workspace'}
          </button>
        </form>

        <p className="text-xs text-neutral-400 mt-6">
          Se crea con un pipeline estándar y canales de envío por configurar. Podrás invitar a tu equipo después.
        </p>
      </div>
    </div>
  );
}
