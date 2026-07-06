'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';
import { Search, Loader2 } from 'lucide-react';

type Hit = {
  id: string;
  full_name: string | null;
  phone: string | null;
  email: string | null;
};

// Barra de búsqueda de contactos existentes para INICIAR una conversación con un
// lead que aún no ha escrito. Solo busca en leads_master (no crea leads). Al
// elegir, navega a /inbox?lead={id}; la página sabe abrir un lead aunque no esté
// en la lista de conversaciones.
export function InboxSearch() {
  const router = useRouter();
  const [q, setQ] = useState('');
  const [hits, setHits] = useState<Hit[]>([]);
  const [loading, setLoading] = useState(false);
  const [open, setOpen] = useState(false);
  const boxRef = useRef<HTMLDivElement>(null);
  // Guardia de secuencia: descarta respuestas de peticiones viejas que resuelven
  // después de una más nueva (race del debounce) y evita reabrir el dropdown.
  const reqSeq = useRef(0);

  useEffect(() => {
    const term = q.trim();
    if (term.length < 2) { setHits([]); setLoading(false); return; }
    setLoading(true);
    const myId = ++reqSeq.current;
    const handle = setTimeout(async () => {
      // Sanitizar: , ( ) * rompen el filtro .or(); % _ \ son comodines LIKE que
      // producen falsos positivos o errores silenciosos.
      const safe = term.replace(/[,()*%_\\]/g, ' ').trim();
      if (!safe) { if (myId === reqSeq.current) { setHits([]); setLoading(false); } return; }
      const supabase = createClient();
      const { data } = await supabase
        .from('leads_master')
        .select('id, full_name, phone, email')
        .or(`full_name.ilike.*${safe}*,phone.ilike.*${safe}*,email.ilike.*${safe}*`)
        .limit(8);
      if (myId !== reqSeq.current) return; // llegó una respuesta más nueva → descartar
      setHits((data as Hit[]) ?? []);
      setLoading(false);
      setOpen(true);
    }, 250);
    return () => clearTimeout(handle);
  }, [q]);

  // Cerrar el dropdown al hacer click fuera.
  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', onClick);
    return () => document.removeEventListener('mousedown', onClick);
  }, []);

  function pick(id: string) {
    setOpen(false);
    setQ('');
    setHits([]);
    router.push(`/inbox?lead=${id}`);
  }

  return (
    <div ref={boxRef} className="relative">
      <div className="relative">
        <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-neutral-400" />
        <input
          value={q}
          onChange={e => setQ(e.target.value)}
          onFocus={() => { if (hits.length) setOpen(true); }}
          placeholder="Buscar contacto para escribirle…"
          className="w-full pl-8 pr-8 py-2 text-sm border border-neutral-200 rounded-md focus:outline-none focus:ring-1 focus:ring-brand-400"
        />
        {loading && <Loader2 size={14} className="absolute right-2.5 top-1/2 -translate-y-1/2 text-neutral-400 animate-spin" />}
      </div>

      {open && (
        <div className="absolute z-20 mt-1 w-full bg-white border border-neutral-200 rounded-md shadow-lg max-h-72 overflow-y-auto">
          {hits.length === 0 && !loading && (
            <p className="px-3 py-2.5 text-xs text-neutral-500">Sin resultados</p>
          )}
          {hits.map(h => (
            <button
              key={h.id}
              onClick={() => pick(h.id)}
              className="block w-full text-left px-3 py-2 hover:bg-neutral-50 border-b border-neutral-100 last:border-0"
            >
              <div className="text-sm text-neutral-900 truncate">
                {h.full_name ?? h.phone ?? h.email ?? 'Sin nombre'}
              </div>
              <div className="text-[11px] text-neutral-500 truncate">
                {[h.phone, h.email].filter(Boolean).join(' · ') || '—'}
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
