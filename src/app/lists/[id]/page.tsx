import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ChevronLeft, Users, Megaphone } from 'lucide-react';
import { SegmentBadge } from '@/components/SegmentBadge';
import { formatDate } from '@/lib/utils';
import { E164_SQL_REGEX } from '@/lib/leadFilters';

export const dynamic = 'force-dynamic';

export default async function ListDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: list }, { data: members, count }, { count: waReady }] = await Promise.all([
    supabase.from('lead_lists').select('id, name, description, source_type, created_at').eq('id', id).maybeSingle(),
    supabase
      .from('leads_master')
      .select('id, full_name, email, phone, marketing_segment, pipeline_stage, lead_list_members!inner(list_id)', { count: 'exact' })
      .eq('lead_list_members.list_id', id)
      .order('updated_at', { ascending: false })
      .limit(100),
    supabase
      .from('leads_master')
      .select('id, lead_list_members!inner(list_id)', { count: 'exact', head: true })
      .eq('lead_list_members.list_id', id)
      .eq('can_whatsapp', true)
      .filter('phone', 'match', E164_SQL_REGEX),
  ]);

  if (!list) notFound();

  return (
    <div className="p-8 max-w-5xl">
      <Link href="/lists" className="inline-flex items-center gap-1 text-xs text-neutral-500 hover:text-neutral-700 mb-5">
        <ChevronLeft size={14} /> Listas
      </Link>

      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-neutral-900">{list.name}</h1>
          <p className="text-sm text-neutral-500 mt-1">
            {(count ?? 0).toLocaleString('es-CO')} miembros · {(waReady ?? 0).toLocaleString('es-CO')} con WhatsApp válido (E.164) · creada {formatDate(list.created_at)}
            {list.description && <> · {list.description}</>}
          </p>
        </div>
        <div className="flex gap-2">
          <Link
            href={`/leads?list=${list.id}`}
            className="inline-flex items-center gap-1.5 px-3 py-2 text-sm border border-neutral-200 rounded-md hover:bg-neutral-50"
          >
            <Users size={14} /> Ver en Leads
          </Link>
          <Link
            href="/campaigns/new"
            className="inline-flex items-center gap-1.5 px-3 py-2 text-sm bg-brand-600 hover:bg-brand-700 text-white rounded-md font-medium"
          >
            <Megaphone size={14} /> Campaña a esta lista
          </Link>
        </div>
      </div>

      <div className="bg-white border border-neutral-200 rounded-lg overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs text-neutral-500 border-b border-neutral-100 bg-neutral-50">
              <th className="px-4 py-2.5 font-medium">Lead</th>
              <th className="px-4 py-2.5 font-medium">Email</th>
              <th className="px-4 py-2.5 font-medium">Teléfono</th>
              <th className="px-4 py-2.5 font-medium">Segmento</th>
            </tr>
          </thead>
          <tbody>
            {(members ?? []).map((m: any) => (
              <tr key={m.id} className="border-b border-neutral-50 hover:bg-neutral-50">
                <td className="px-4 py-2.5">
                  <Link href={`/leads/${m.id}`} className="font-medium text-neutral-900 hover:text-brand-700">
                    {m.full_name ?? 'Sin nombre'}
                  </Link>
                </td>
                <td className="px-4 py-2.5 text-neutral-600">{m.email ?? '—'}</td>
                <td className="px-4 py-2.5 text-neutral-600">{m.phone ?? '—'}</td>
                <td className="px-4 py-2.5"><SegmentBadge segment={m.marketing_segment} /></td>
              </tr>
            ))}
          </tbody>
        </table>
        {(count ?? 0) > 100 && (
          <div className="px-4 py-2.5 text-xs text-neutral-500 border-t border-neutral-100">
            Mostrando 100 de {(count ?? 0).toLocaleString('es-CO')} — usa <Link href={`/leads?list=${list.id}`} className="text-brand-600 hover:underline">Leads</Link> para ver y filtrar todos.
          </div>
        )}
      </div>
    </div>
  );
}
