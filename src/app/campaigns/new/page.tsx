import { createClient } from '@/lib/supabase/server';
import Link from 'next/link';
import { ChevronLeft } from 'lucide-react';
import { CampaignForm } from './CampaignForm';

export const dynamic = 'force-dynamic';

export default async function NewCampaignPage() {
  const supabase = await createClient();

  const [{ data: templates }, { data: lists }] = await Promise.all([
    supabase
      .from('message_templates')
      .select('template_key, name, channel')
      .eq('status', 'active')
      .order('channel')
      .order('name'),
    supabase.rpc('lists_overview'),
  ]);

  return (
    <div className="p-8 max-w-2xl">
      <Link
        href="/campaigns"
        className="inline-flex items-center gap-1 text-xs text-neutral-500 hover:text-neutral-700 mb-5"
      >
        <ChevronLeft size={14} /> Campañas
      </Link>

      <div className="mb-6">
        <h1 className="text-2xl font-semibold text-neutral-900">Nueva campaña</h1>
        <p className="text-sm text-neutral-500 mt-1">
          Define el canal, template y segmento. Luego la lanzas desde la pantalla de detalle.
        </p>
      </div>

      <div className="bg-white border border-neutral-200 rounded-lg p-6">
        <CampaignForm templates={templates ?? []} lists={(lists ?? []).map((l: any) => ({ id: l.id, name: l.name, members: Number(l.members) }))} />
      </div>
    </div>
  );
}
