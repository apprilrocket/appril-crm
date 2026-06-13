import { createClient } from '@/lib/supabase/server';
import { notFound } from 'next/navigation';
import { TemplateForm } from './TemplateForm';

export const dynamic = 'force-dynamic';

export default async function TemplatePage({ params }: { params: { id: string } }) {
  const supabase = await createClient();

  let template = null;
  if (params.id !== 'new') {
    const { data } = await supabase
      .from('message_templates')
      .select('id, template_key, name, channel, status, subject, html_body, text_body, wa_template_name, wa_language')
      .eq('id', params.id)
      .single();
    if (!data) notFound();
    template = data;
  }

  return (
    <div className="p-8 max-w-3xl">
      <div className="mb-6">
        <h1 className="text-2xl font-semibold text-neutral-900">
          {template ? 'Editar template' : 'Nuevo template'}
        </h1>
        {template && (
          <p className="text-xs text-neutral-400 font-mono mt-1">key: {template.template_key}</p>
        )}
      </div>
      <TemplateForm template={template} />
    </div>
  );
}
