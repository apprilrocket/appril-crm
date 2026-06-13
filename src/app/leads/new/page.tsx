import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';
import { NewLeadForm } from './NewLeadForm';

export const dynamic = 'force-dynamic';

export default async function NewLeadPage() {
  const supabase = await createClient();
  const { data: stages } = await supabase
    .from('pipeline_stages')
    .select('key, label')
    .order('position');

  return (
    <div className="p-8 max-w-2xl">
      <Link href="/leads" className="text-sm text-neutral-500 hover:text-neutral-900 inline-flex items-center gap-1 mb-4">
        <ArrowLeft size={14} /> Volver a leads
      </Link>
      <h1 className="text-2xl font-semibold text-neutral-900">Nuevo lead</h1>
      <p className="text-sm text-neutral-500 mt-1">Crea un lead manualmente. Necesita al menos email o teléfono.</p>

      <NewLeadForm stages={stages ?? []} />
    </div>
  );
}
