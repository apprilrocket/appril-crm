import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { Search, Plus, Flame } from 'lucide-react';
import { applyLeadFilters, filterFromSearchParams, SEGMENTS } from '@/lib/leadFilters';
import { LeadsTable, type LeadRow } from './LeadsTable';

export const dynamic = 'force-dynamic';

const PAGE_SIZE = 50;

type SearchParams = {
  q?: string;
  segment?: string;
  stage?: string;
  channel?: 'email' | 'whatsapp';
  city?: string;
  source?: string;
  specialization?: string;
  uncontacted?: string;
  paying?: string;
  sort?: 'heat' | 'recent';
  warming?: string;
  page?: string;
  list?: string;
  quality?: string;
};

const QUALITY_LABELS: Record<string, string> = {
  no_email: 'sin email',
  no_phone: 'sin teléfono',
  bad_phone: 'con teléfono inválido (no E.164)',
  no_name: 'sin nombre',
};

type FilterOption = { value: string; count: number };

export default async function LeadsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const page = Math.max(1, parseInt(sp.page ?? '1'));
  const offset = (page - 1) * PAGE_SIZE;
  const supabase = await createClient();
  const filter = filterFromSearchParams(sp);

  const baseSelect = 'id, full_name, email, phone, marketing_segment, pipeline_stage, source, can_email, can_whatsapp, last_contacted_at, total_citas, pagando_hoy, engagement_score, last_engaged_at';
  // El filtro por lista requiere el inner join con lead_list_members
  const select = sp.list ? `${baseSelect}, lead_list_members!inner(list_id)` : baseSelect;

  let q = supabase
    .from('leads_master')
    .select(select, { count: 'exact' })
    .range(offset, offset + PAGE_SIZE - 1);

  if (sp.sort === 'heat') {
    q = q.order('engagement_score', { ascending: false }).order('last_engaged_at', { ascending: false, nullsFirst: false });
  } else {
    q = q.order('updated_at', { ascending: false });
  }

  q = applyLeadFilters(q, filter);

  const [{ data: leads, count }, { data: stageRows }, { data: options }, { data: activeList }] = await Promise.all([
    q,
    supabase.from('pipeline_stages').select('key, label, color').order('position'),
    supabase.rpc('lead_filter_options'),
    sp.list
      ? supabase.from('lead_lists').select('id, name').eq('id', sp.list).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const totalPages = Math.ceil((count ?? 0) / PAGE_SIZE);
  const warmingActive = sp.warming === '1';
  const sources: FilterOption[] = options?.sources ?? [];
  const cities: FilterOption[] = options?.cities ?? [];
  const specializations: FilterOption[] = options?.specializations ?? [];

  const activeExtraFilters = [sp.city, sp.source, sp.specialization, sp.uncontacted, sp.paying].filter(Boolean).length;

  return (
    <div className="p-8 max-w-7xl">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-neutral-900">Leads</h1>
          <p className="text-sm text-neutral-500 mt-1">
            {(count ?? 0).toLocaleString('es-CO')} leads {warmingActive ? 'calentándose' : 'coinciden'}
            {activeList && <> · en lista <Link href={`/lists/${activeList.id}`} className="text-brand-600 hover:underline font-medium">{activeList.name}</Link></>}
            {sp.quality && QUALITY_LABELS[sp.quality] && <> · {QUALITY_LABELS[sp.quality]}</>}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Link
            href={warmingActive ? '/leads' : '/leads?warming=1&sort=heat'}
            className={`inline-flex items-center gap-1.5 px-3 py-2 text-sm rounded-md border ${
              warmingActive
                ? 'bg-orange-50 border-orange-300 text-orange-700 font-medium'
                : 'border-neutral-200 text-neutral-700 hover:bg-neutral-50'
            }`}
          >
            <Flame size={14} /> Calentándose
          </Link>
          <Link
            href="/leads/new"
            className="inline-flex items-center gap-1.5 px-3 py-2 bg-brand-600 hover:bg-brand-700 text-white text-sm font-medium rounded-md"
          >
            <Plus size={14} /> Nuevo lead
          </Link>
        </div>
      </div>

      <form className="bg-white border border-neutral-200 rounded-lg p-3 mb-4">
        {warmingActive && <input type="hidden" name="warming" value="1" />}
        {sp.sort && <input type="hidden" name="sort" value={sp.sort} />}

        <div className="flex flex-wrap gap-2">
          <div className="relative flex-1 min-w-[220px]">
            <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-neutral-400" />
            <input
              name="q"
              defaultValue={sp.q ?? ''}
              placeholder="Buscar por nombre, email, teléfono, ciudad o especialidad…"
              className="w-full pl-9 pr-3 py-1.5 text-sm border border-neutral-200 rounded-md"
            />
          </div>
          <Select name="segment" defaultValue={sp.segment ?? ''} options={[['', 'Todos los segmentos'], ...SEGMENTS.map(s => [s, s] as [string, string])]} />
          <Select name="stage" defaultValue={sp.stage ?? ''} options={[['', 'Todas las etapas'], ...(stageRows ?? []).map(s => [s.key, s.label] as [string, string])]} />
          <Select name="channel" defaultValue={sp.channel ?? ''} options={[['', 'Cualquier canal'], ['email', 'Email OK'], ['whatsapp', 'WhatsApp OK']]} />
          <button type="submit" className="px-3 py-1.5 bg-brand-600 hover:bg-brand-700 text-white text-sm rounded-md">Filtrar</button>
        </div>

        <details className="mt-2" open={activeExtraFilters > 0}>
          <summary className="text-xs text-neutral-500 cursor-pointer hover:text-neutral-800 select-none">
            Más filtros{activeExtraFilters > 0 ? ` (${activeExtraFilters} activos)` : ''}
          </summary>
          <div className="flex flex-wrap items-center gap-2 mt-2">
            <Select
              name="source"
              defaultValue={sp.source ?? ''}
              options={[['', 'Todas las fuentes'], ...sources.map(s => [s.value, `${s.value} (${s.count.toLocaleString('es-CO')})`] as [string, string])]}
            />
            <input
              name="city"
              defaultValue={sp.city ?? ''}
              list="cities-list"
              placeholder="Ciudad"
              className="px-2 py-1.5 text-sm border border-neutral-200 rounded-md w-36"
            />
            <datalist id="cities-list">
              {cities.map(c => <option key={c.value} value={c.value}>{`${c.value} (${c.count})`}</option>)}
            </datalist>
            <input
              name="specialization"
              defaultValue={sp.specialization ?? ''}
              list="spec-list"
              placeholder="Especialidad"
              className="px-2 py-1.5 text-sm border border-neutral-200 rounded-md w-44"
            />
            <datalist id="spec-list">
              {specializations.map(s => <option key={s.value} value={s.value}>{`${s.value} (${s.count})`}</option>)}
            </datalist>
            <label className="inline-flex items-center gap-1.5 text-sm text-neutral-700 px-2 py-1.5 border border-neutral-200 rounded-md cursor-pointer hover:bg-neutral-50">
              <input type="checkbox" name="uncontacted" value="1" defaultChecked={sp.uncontacted === '1'} className="accent-brand-600" />
              Nunca contactados
            </label>
            <label className="inline-flex items-center gap-1.5 text-sm text-neutral-700 px-2 py-1.5 border border-neutral-200 rounded-md cursor-pointer hover:bg-neutral-50">
              <input type="checkbox" name="paying" value="1" defaultChecked={sp.paying === '1'} className="accent-brand-600" />
              💰 Pagando hoy
            </label>
            <Link href="/leads" className="text-xs text-neutral-500 hover:text-neutral-800 underline">Limpiar todo</Link>
          </div>
        </details>
      </form>

      <LeadsTable
        leads={(leads ?? []) as LeadRow[]}
        stages={stageRows ?? []}
        filter={filter}
        totalCount={count ?? 0}
        sortHref={buildHref(sp, { sort: sp.sort === 'heat' ? undefined : 'heat', page: undefined })}
        sortedByHeat={sp.sort === 'heat'}
      />

      {totalPages > 1 && (
        <div className="flex items-center justify-between mt-4 text-sm">
          <div className="text-neutral-500">Página {page} de {totalPages}</div>
          <div className="flex gap-2">
            {page > 1          && <Link href={buildHref(sp, { page: page - 1 })} className="px-3 py-1 border border-neutral-200 rounded-md hover:bg-neutral-50">← Anterior</Link>}
            {page < totalPages && <Link href={buildHref(sp, { page: page + 1 })} className="px-3 py-1 border border-neutral-200 rounded-md hover:bg-neutral-50">Siguiente →</Link>}
          </div>
        </div>
      )}
    </div>
  );
}

function Select({ name, defaultValue, options }: { name: string; defaultValue: string; options: [string, string][] }) {
  return (
    <select name={name} defaultValue={defaultValue} className="px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white">
      {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
    </select>
  );
}

function buildHref(sp: SearchParams, overrides: Partial<Record<'sort' | 'page', string | number | undefined>>) {
  const params = new URLSearchParams();
  for (const key of ['q', 'segment', 'stage', 'channel', 'city', 'source', 'specialization', 'uncontacted', 'paying', 'warming', 'list', 'quality'] as const) {
    if (sp[key]) params.set(key, sp[key]!);
  }
  const sort = 'sort' in overrides ? overrides.sort : sp.sort;
  if (sort) params.set('sort', String(sort));
  const page = 'page' in overrides ? overrides.page : sp.page;
  if (page) params.set('page', String(page));
  const qs = params.toString();
  return qs ? `/leads?${qs}` : '/leads';
}
