'use client';

import { useState } from 'react';
import { createClient } from '@/lib/supabase/client';

const GOOGLE_ENABLED = process.env.NEXT_PUBLIC_AUTH_GOOGLE === '1';

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/callback`
      }
    });

    setLoading(false);
    if (error) setError(error.message);
    else setSent(true);
  }

  async function signInWithGoogle() {
    setError(null);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback`
      }
    });
    if (error) setError(error.message);
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-neutral-50 px-4">
      <div className="w-full max-w-sm bg-white border border-neutral-200 rounded-lg p-8">
        <h1 className="text-xl font-semibold text-neutral-900">CRM</h1>
        <p className="text-sm text-neutral-500 mt-1">
          Entra o crea tu cuenta. Si es tu primera vez, después de entrar creas tu workspace.
        </p>

        {GOOGLE_ENABLED && (
          <>
            <button
              onClick={signInWithGoogle}
              className="mt-6 w-full flex items-center justify-center gap-2 border border-neutral-300 hover:bg-neutral-50 text-neutral-800 py-2 rounded-md text-sm font-medium transition-colors"
            >
              <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden="true">
                <path fill="#FFC107" d="M43.6 20.1H42V20H24v8h11.3c-1.6 4.7-6.1 8-11.3 8-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.9 1.2 8 3l5.7-5.7C34.2 6.1 29.3 4 24 4 13 4 4 13 4 24s9 20 20 20 20-9 20-20c0-1.3-.1-2.6-.4-3.9z"/>
                <path fill="#FF3D00" d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.9 1.2 8 3l5.7-5.7C34.2 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/>
                <path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.6 39.6 16.2 44 24 44z"/>
                <path fill="#1976D2" d="M43.6 20.1H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C41.4 35.3 44 30.1 44 24c0-1.3-.1-2.6-.4-3.9z"/>
              </svg>
              Continuar con Google
            </button>
            <div className="flex items-center gap-3 my-5">
              <div className="flex-1 h-px bg-neutral-200" />
              <span className="text-xs text-neutral-400">o con tu email</span>
              <div className="flex-1 h-px bg-neutral-200" />
            </div>
          </>
        )}

        {sent ? (
          <div className="mt-6 text-sm text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-md p-3">
            Listo. Revisa tu inbox y haz click en el link para entrar.
          </div>
        ) : (
          <form onSubmit={onSubmit} className={GOOGLE_ENABLED ? 'space-y-3' : 'mt-6 space-y-3'}>
            <input
              type="email"
              required
              placeholder="tu@email.com"
              value={email}
              onChange={e => setEmail(e.target.value)}
              className="w-full px-3 py-2 border border-neutral-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-brand-500 focus:border-transparent"
            />
            {error && <div className="text-xs text-red-600">{error}</div>}
            <button
              type="submit"
              disabled={loading}
              className="w-full bg-brand-600 hover:bg-brand-700 disabled:opacity-50 text-white py-2 rounded-md text-sm font-medium transition-colors"
            >
              {loading ? 'Enviando…' : 'Enviar magic link'}
            </button>
          </form>
        )}

        <p className="text-xs text-neutral-400 mt-6">
          Al continuar aceptas el uso responsable de los canales de envío de tu workspace.
        </p>
      </div>
    </div>
  );
}
