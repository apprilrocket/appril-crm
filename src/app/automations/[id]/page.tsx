import { createClient } from '@/lib/supabase/server';
import { notFound } from 'next/navigation';
import { FlowBuilder } from './FlowBuilder';

export const dynamic = 'force-dynamic';

export default async function AutomationBuilderPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: automation }, { data: templates }, { data: stages }, { data: runs }] = await Promise.all([
    supabase.from('automations').select('*').eq('id', id).single(),
    supabase.from('message_templates').select('template_key, name, channel').eq('status', 'active'),
    supabase.from('pipeline_stages').select('key, label').order('position'),
    supabase.from('automation_runs').select('status').eq('automation_id', id)
  ]);

  if (!automation) notFound();

  const stats = { active: 0, converted: 0, completed: 0, failed: 0 };
  for (const r of runs ?? []) {
    if (r.status === 'active') stats.active++;
    else if (r.status === 'converted') stats.converted++;
    else if (r.status === 'failed') stats.failed++;
    else stats.completed++;
  }

  return (
    <FlowBuilder
      automation={{
        id: automation.id,
        name: automation.name,
        status: automation.status,
        flow: automation.flow ?? { nodes: [], edges: [] }
      }}
      templates={templates ?? []}
      stages={stages ?? []}
      stats={stats}
    />
  );
}
