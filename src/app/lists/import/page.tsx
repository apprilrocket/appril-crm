import Link from 'next/link';
import { ChevronLeft } from 'lucide-react';
import { ImportWizard } from './ImportWizard';

export const dynamic = 'force-dynamic';

export default function ImportPage() {
  return (
    <div className="p-8 max-w-3xl">
      <Link href="/lists" className="inline-flex items-center gap-1 text-xs text-neutral-500 hover:text-neutral-700 mb-5">
        <ChevronLeft size={14} /> Listas
      </Link>
      <div className="mb-6">
        <h1 className="text-2xl font-semibold text-neutral-900">Importar leads a una lista</h1>
        <p className="text-sm text-neutral-500 mt-1">
          Sube un CSV, mapea las columnas y el sistema deduplica contra toda la base.
          Los teléfonos deben incluir el indicativo del país (ej: +573001234567) — nunca se adivina el país.
        </p>
      </div>
      <ImportWizard />
    </div>
  );
}
