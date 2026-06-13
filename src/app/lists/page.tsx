import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { ListChecks, Plus, Upload } from 'lucide-react';
import { formatDate } from '@/lib/utils';

export const dynamic = 'force-dynamic';

type ListRow = {
  id: string;
  name: string;
  description: string | null;
  source_type: string;
  created_at: string;
  members: number;
};

const SOURCE_LABELS: Record<string, string> = {
  csv_import: 'Import CSV',
  webhook: 'Webhook',
  manual: 'Manual',
};

export default async function ListsPage() {
  const supabase = await createClient();
  const { data } = await supabase.rpc('lists_overview');
  const lists: ListRow[] = data ?? [];

  return (
    <div className="p-8 max-w-5xl">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-neutral-900 flex items-center gap-2">
            <ListChecks size={24} /> Listas
          </h1>
          <p className="text-sm text-neutral-500 mt-1">
            Agrupa leads por fuente o propósito. Un lead puede estar en varias listas.
          </p>
        </div>
        <Link
          href="/lists/import"
          className="inline-flex items-center gap-1.5 px-3 py-2 bg-brand-600 hover:bg-brand-700 text-white text-sm font-medium rounded-md"
        >
          <Upload size={14} /> Importar CSV
        </Link>
      </div>

      {lists.length === 0 ? (
        <div className="bg-white border border-neutral-200 rounded-lg p-10 text-center">
          <p className="text-neutral-500 text-sm mb-3">Aún no hay listas.</p>
          <Link href="/lists/import" className="inline-flex items-center gap-1.5 text-sm text-brand-600 hover:underline">
            <Plus size={14} /> Crea la primera importando un CSV
          </Link>
        </div>
      ) : (
        <div className="bg-white border border-neutral-200 rounded-lg overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs text-neutral-500 border-b border-neutral-100 bg-neutral-50">
                <th className="px-4 py-2.5 font-medium">Lista</th>
                <th className="px-4 py-2.5 font-medium">Fuente</th>
                <th className="px-4 py-2.5 font-medium text-right">Miembros</th>
                <th className="px-4 py-2.5 font-medium text-right">Creada</th>
              </tr>
            </thead>
            <tbody>
              {lists.map(l => (
                <tr key={l.id} className="border-b border-neutral-50 hover:bg-neutral-50">
                  <td className="px-4 py-3">
                    <Link href={`/lists/${l.id}`} className="font-medium text-neutral-900 hover:text-brand-700">
                      {l.name}
                    </Link>
                    {l.description && <div className="text-xs text-neutral-500 mt-0.5">{l.description}</div>}
                  </td>
                  <td className="px-4 py-3 text-neutral-600">{SOURCE_LABELS[l.source_type] ?? l.source_type}</td>
                  <td className="px-4 py-3 text-right font-medium">{Number(l.members).toLocaleString('es-CO')}</td>
                  <td className="px-4 py-3 text-right text-neutral-500">{formatDate(l.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
