'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import Papa from 'papaparse';
import { createClient } from '@/lib/supabase/client';
import { parsePhoneStrict, normalizeEmail } from '@/lib/phone';
import { Upload, ArrowRight, CheckCircle2, AlertTriangle } from 'lucide-react';

type Step = 'upload' | 'map' | 'running' | 'done';

// Campos del CRM a los que se puede mapear una columna del CSV
const TARGETS = [
  { key: 'full_name', label: 'Nombre completo' },
  { key: 'email', label: 'Email' },
  { key: 'phone', label: 'Teléfono (con indicativo +XX)' },
  { key: 'city', label: 'Ciudad' },
  { key: 'country', label: 'País' },
  { key: 'specialization', label: 'Especialidad' },
  { key: '', label: '— Ignorar columna —' },
] as const;

type Report = {
  total: number;
  nuevos: number;
  existentes: number;
  invalidos: number;        // sin email válido ni teléfono válido → no importados
  duplicadosArchivo: number;
  telDescartado: number;    // importados por email, pero su teléfono no era E.164
  telSinIndicativo: number; // subconjunto de telDescartado/invalidos por falta de '+'
};

// Auto-mapeo por nombre de encabezado
function guessTarget(header: string): string {
  const h = header.toLowerCase().trim();
  if (/correo|e-?mail/.test(h)) return 'email';
  if (/tel|cel|phone|whatsapp|movil|móvil/.test(h)) return 'phone';
  if (/nombre|name/.test(h)) return 'full_name';
  if (/ciudad|city/.test(h)) return 'city';
  if (/pa[ií]s|country/.test(h)) return 'country';
  if (/especialidad|specialt/.test(h)) return 'specialization';
  return '';
}

export function ImportWizard() {
  const router = useRouter();
  const [step, setStep] = useState<Step>('upload');
  const [listName, setListName] = useState('');
  const [source, setSource] = useState('');
  const [headers, setHeaders] = useState<string[]>([]);
  const [rows, setRows] = useState<Record<string, string>[]>([]);
  const [mapping, setMapping] = useState<Record<string, string>>({});
  const [progress, setProgress] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<Report | null>(null);
  const [listId, setListId] = useState<string | null>(null);

  function onFile(file: File) {
    setError(null);
    Papa.parse<Record<string, string>>(file, {
      header: true,
      skipEmptyLines: 'greedy',
      complete: (res) => {
        const hs = res.meta.fields ?? [];
        if (hs.length === 0 || res.data.length === 0) {
          setError('El archivo está vacío o no tiene encabezados.');
          return;
        }
        setHeaders(hs);
        setRows(res.data);
        const auto: Record<string, string> = {};
        hs.forEach(h => { auto[h] = guessTarget(h); });
        setMapping(auto);
        if (!listName) setListName(file.name.replace(/\.[^.]+$/, ''));
        setStep('map');
      },
      error: (err) => setError(`No se pudo leer el archivo: ${err.message}`),
    });
  }

  async function runImport() {
    setError(null);
    const mapped = Object.entries(mapping).filter(([, t]) => t);
    const hasContact = mapped.some(([, t]) => t === 'email') || mapped.some(([, t]) => t === 'phone');
    if (!hasContact) { setError('Mapea al menos la columna de email o la de teléfono.'); return; }
    if (!listName.trim()) { setError('Ponle nombre a la lista.'); return; }

    setStep('running');
    const supabase = createClient();

    try {
      const { data: ws } = await supabase.from('crm_users').select('workspace_id').limit(1).single();
      const wsId = ws?.workspace_id;
      if (!wsId) throw new Error('No se encontró workspace');

      // 1. Crear la lista
      setProgress('Creando lista…');
      const { data: list, error: listErr } = await supabase
        .from('lead_lists')
        .insert({ workspace_id: wsId, name: listName.trim(), source_type: 'csv_import', description: source.trim() || null })
        .select('id')
        .single();
      if (listErr) throw new Error(listErr.code === '23505' ? 'Ya existe una lista con ese nombre.' : listErr.message);
      setListId(list.id);

      // 2. Normalizar filas
      setProgress('Validando filas…');
      const get = (row: Record<string, string>, target: string) => {
        const col = mapped.find(([, t]) => t === target)?.[0];
        return col ? (row[col] ?? '').trim() : '';
      };

      const seenEmail = new Set<string>();
      const seenPhone = new Set<string>();
      const rep: Report = { total: rows.length, nuevos: 0, existentes: 0, invalidos: 0, duplicadosArchivo: 0, telDescartado: 0, telSinIndicativo: 0 };

      type Rec = { full_name: string | null; email: string | null; phone: string | null; city: string | null; country: string | null; specialization: string | null };
      const records: Rec[] = [];

      for (const row of rows) {
        const email = normalizeEmail(get(row, 'email'));
        const rawPhone = get(row, 'phone');
        const phoneRes = rawPhone ? parsePhoneStrict(rawPhone) : null;
        const phone = phoneRes?.ok ? phoneRes.e164 : null;

        if (phoneRes && !phoneRes.ok && phoneRes.reason === 'sin indicativo') rep.telSinIndicativo++;
        if (rawPhone && !phone) rep.telDescartado++;

        if (!email && !phone) { rep.invalidos++; continue; }

        // dedupe dentro del archivo
        if ((email && seenEmail.has(email)) || (phone && seenPhone.has(phone))) {
          rep.duplicadosArchivo++;
          continue;
        }
        if (email) seenEmail.add(email);
        if (phone) seenPhone.add(phone);

        records.push({
          full_name: get(row, 'full_name') || null,
          email,
          phone,
          city: get(row, 'city') || null,
          country: get(row, 'country') || null,
          specialization: get(row, 'specialization') || null,
        });
      }

      // 3. Buscar existentes en toda la base (por email normalizado y por phone E.164)
      setProgress(`Buscando duplicados en la base (${records.length} filas válidas)…`);
      const byEmail = new Map<string, string>(); // email → lead_id
      const byPhone = new Map<string, string>();
      const CHUNK = 300;

      const emails = records.map(r => r.email).filter(Boolean) as string[];
      for (let i = 0; i < emails.length; i += CHUNK) {
        const { data } = await supabase
          .from('leads_master')
          .select('id, email_normalized')
          .in('email_normalized', emails.slice(i, i + CHUNK));
        (data ?? []).forEach(l => { if (l.email_normalized) byEmail.set(l.email_normalized, l.id); });
      }
      const phones = records.map(r => r.phone).filter(Boolean) as string[];
      for (let i = 0; i < phones.length; i += CHUNK) {
        const { data } = await supabase
          .from('leads_master')
          .select('id, phone')
          .in('phone', phones.slice(i, i + CHUNK));
        (data ?? []).forEach(l => { if (l.phone) byPhone.set(l.phone, l.id); });
      }

      const memberIds = new Set<string>();
      const toCreate: Rec[] = [];
      for (const r of records) {
        const existingId = (r.email && byEmail.get(r.email)) || (r.phone && byPhone.get(r.phone)) || null;
        if (existingId) { memberIds.add(existingId); rep.existentes++; }
        else toCreate.push(r);
      }

      // 4. Crear leads nuevos
      for (let i = 0; i < toCreate.length; i += CHUNK) {
        setProgress(`Creando leads nuevos… ${Math.min(i + CHUNK, toCreate.length)}/${toCreate.length}`);
        const batch = toCreate.slice(i, i + CHUNK).map(r => ({
          workspace_id: wsId,
          full_name: r.full_name,
          email: r.email,
          phone: r.phone,
          city: r.city,
          country: r.country,
          specialization: r.specialization,
          source: `lista:${listName.trim()}`,
          marketing_segment: 'COLD',
          pipeline_stage: 'new',
          can_email: !!r.email,
          can_whatsapp: !!r.phone,
          whatsapp_opted_in: false,
        }));
        const { data: created, error: insErr } = await supabase
          .from('leads_master')
          .insert(batch)
          .select('id');
        if (insErr) throw new Error(`Error creando leads: ${insErr.message}`);
        (created ?? []).forEach(l => memberIds.add(l.id));
        rep.nuevos += created?.length ?? 0;
      }

      // 5. Agregar todos a la lista
      const members = Array.from(memberIds).map(lead_id => ({ list_id: list.id, lead_id }));
      for (let i = 0; i < members.length; i += CHUNK) {
        setProgress(`Agregando a la lista… ${Math.min(i + CHUNK, members.length)}/${members.length}`);
        const { error: memErr } = await supabase
          .from('lead_list_members')
          .upsert(members.slice(i, i + CHUNK), { onConflict: 'list_id,lead_id', ignoreDuplicates: true });
        if (memErr) throw new Error(`Error agregando a la lista: ${memErr.message}`);
      }

      setReport(rep);
      setStep('done');
      router.refresh();
    } catch (e: any) {
      setError(e.message ?? String(e));
      setStep('map');
    }
  }

  if (step === 'upload') {
    return (
      <div className="bg-white border border-neutral-200 rounded-lg p-6 space-y-4">
        <div>
          <label className="block text-xs font-medium text-neutral-500 mb-1.5">Nombre de la lista *</label>
          <input
            value={listName}
            onChange={e => setListName(e.target.value)}
            placeholder="Ej: Congreso odontología Bogotá 2026"
            className="w-full px-3 py-2 text-sm border border-neutral-200 rounded-md"
          />
        </div>
        <div>
          <label className="block text-xs font-medium text-neutral-500 mb-1.5">Fuente / nota (opcional)</label>
          <input
            value={source}
            onChange={e => setSource(e.target.value)}
            placeholder="¿De dónde viene esta base?"
            className="w-full px-3 py-2 text-sm border border-neutral-200 rounded-md"
          />
        </div>
        <label className="flex flex-col items-center justify-center gap-2 border-2 border-dashed border-neutral-300 rounded-lg py-10 cursor-pointer hover:border-brand-400 hover:bg-brand-50/30 transition-colors">
          <Upload size={22} className="text-neutral-400" />
          <span className="text-sm text-neutral-600">Arrastra o haz clic para subir un CSV</span>
          <span className="text-xs text-neutral-400">Con encabezados en la primera fila</span>
          <input
            type="file"
            accept=".csv,text/csv"
            className="hidden"
            onChange={e => { const f = e.target.files?.[0]; if (f) onFile(f); }}
          />
        </label>
        {error && <p className="text-sm text-red-600">{error}</p>}
      </div>
    );
  }

  if (step === 'map') {
    const preview = rows.slice(0, 3);
    return (
      <div className="bg-white border border-neutral-200 rounded-lg p-6 space-y-5">
        <div>
          <h2 className="font-medium text-neutral-900">Mapea las columnas</h2>
          <p className="text-xs text-neutral-500 mt-0.5">
            {rows.length.toLocaleString('es-CO')} filas detectadas → lista «{listName}». El teléfono debe traer indicativo (+57, +52…) o se descarta.
          </p>
        </div>
        <div className="space-y-2">
          {headers.map(h => (
            <div key={h} className="flex items-center gap-3">
              <div className="w-1/3">
                <div className="text-sm font-medium text-neutral-800 truncate">{h}</div>
                <div className="text-[11px] text-neutral-400 truncate">
                  {preview.map(r => r[h]).filter(Boolean).slice(0, 2).join(' · ') || '(vacío)'}
                </div>
              </div>
              <ArrowRight size={14} className="text-neutral-300 shrink-0" />
              <select
                value={mapping[h] ?? ''}
                onChange={e => setMapping(m => ({ ...m, [h]: e.target.value }))}
                className="flex-1 px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white"
              >
                {TARGETS.map(t => <option key={t.key} value={t.key}>{t.label}</option>)}
              </select>
            </div>
          ))}
        </div>
        {error && <p className="text-sm text-red-600">{error}</p>}
        <div className="flex justify-between border-t border-neutral-100 pt-4">
          <button onClick={() => setStep('upload')} className="px-4 py-2 text-sm text-neutral-600 border border-neutral-200 rounded-md hover:bg-neutral-50">
            ← Atrás
          </button>
          <button onClick={runImport} className="px-5 py-2 text-sm bg-brand-600 hover:bg-brand-700 text-white rounded-md font-medium">
            Importar {rows.length.toLocaleString('es-CO')} filas
          </button>
        </div>
      </div>
    );
  }

  if (step === 'running') {
    return (
      <div className="bg-white border border-neutral-200 rounded-lg p-10 text-center">
        <div className="animate-spin w-8 h-8 border-2 border-brand-600 border-t-transparent rounded-full mx-auto mb-4" />
        <p className="text-sm text-neutral-600">{progress}</p>
      </div>
    );
  }

  // done
  return (
    <div className="bg-white border border-neutral-200 rounded-lg p-6 space-y-4">
      <div className="flex items-center gap-2 text-emerald-700">
        <CheckCircle2 size={20} />
        <h2 className="font-medium">Import completado — «{listName}»</h2>
      </div>
      {report && (
        <div className="grid grid-cols-2 gap-3 text-sm">
          <Stat label="Filas en el archivo" value={report.total} />
          <Stat label="Leads nuevos creados" value={report.nuevos} tone="text-emerald-700" />
          <Stat label="Ya existían (agregados a la lista)" value={report.existentes} />
          <Stat label="Duplicados dentro del archivo" value={report.duplicadosArchivo} />
          <Stat label="Sin email ni teléfono válido (no importados)" value={report.invalidos} tone={report.invalidos > 0 ? 'text-red-600' : undefined} />
          <Stat label="Teléfonos descartados (no E.164)" value={report.telDescartado} tone={report.telDescartado > 0 ? 'text-amber-700' : undefined} />
        </div>
      )}
      {report && report.telSinIndicativo > 0 && (
        <p className="flex items-start gap-1.5 text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-md px-3 py-2">
          <AlertTriangle size={13} className="mt-0.5 shrink-0" />
          {report.telSinIndicativo.toLocaleString('es-CO')} teléfonos venían sin indicativo de país (+XX) y fueron descartados.
          Corrige el archivo y vuelve a importar a la misma lista: los ya existentes no se duplican.
        </p>
      )}
      <div className="flex gap-2 pt-2">
        {listId && (
          <Link href={`/leads?list=${listId}`} className="px-4 py-2 text-sm bg-brand-600 hover:bg-brand-700 text-white rounded-md font-medium">
            Ver leads de la lista
          </Link>
        )}
        <Link href="/lists" className="px-4 py-2 text-sm border border-neutral-200 rounded-md hover:bg-neutral-50">
          Todas las listas
        </Link>
      </div>
    </div>
  );
}

function Stat({ label, value, tone }: { label: string; value: number; tone?: string }) {
  return (
    <div className="border border-neutral-100 rounded-md px-3 py-2">
      <div className={`text-lg font-semibold ${tone ?? 'text-neutral-900'}`}>{value.toLocaleString('es-CO')}</div>
      <div className="text-xs text-neutral-500">{label}</div>
    </div>
  );
}
