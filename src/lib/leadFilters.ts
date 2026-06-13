// Filtros de la lista de leads, compartidos entre la página (lectura)
// y las acciones en lote (escritura) para que "los que coinciden" sea siempre lo mismo.

export const SEGMENTS = ['SUPER_HOT', 'HOT', 'WARM', 'COLD', 'DO_NOT_EMAIL'];
export const STAGES = ['new', 'contacted', 'engaged', 'qualified', 'converted', 'lost'];

export type LeadsFilter = {
  q?: string;
  segment?: string;
  stage?: string;
  channel?: string;       // 'email' | 'whatsapp'
  warming?: string;       // '1'
  city?: string;
  source?: string;
  specialization?: string;
  uncontacted?: string;   // '1' → nunca contactados
  paying?: string;        // '1' → pagando hoy
  list?: string;          // uuid de lead_lists → requiere select con lead_list_members!inner
  quality?: string;       // 'no_email' | 'no_phone' | 'bad_phone' | 'no_name'
};

// E.164 estricto — debe coincidir con lib/phone.ts y las guardas de campañas
export const E164_SQL_REGEX = '^\\+[1-9][0-9]{7,14}$';

// PostgREST usa comas y paréntesis como sintaxis en .or(); se quitan del término de búsqueda
function sanitizeTerm(term: string): string {
  return term.replace(/[(),]/g, ' ').trim();
}

export function applyLeadFilters(q: any, f: LeadsFilter): any {
  if (f.q) {
    const term = sanitizeTerm(f.q);
    if (term) {
      q = q.or(
        `full_name.ilike.%${term}%,email.ilike.%${term}%,phone.ilike.%${term}%,city.ilike.%${term}%,specialization.ilike.%${term}%`
      );
    }
  }
  if (f.segment && SEGMENTS.includes(f.segment)) q = q.eq('marketing_segment', f.segment);
  if (f.stage && STAGES.includes(f.stage)) q = q.eq('pipeline_stage', f.stage);
  if (f.channel === 'email') q = q.eq('can_email', true);
  if (f.channel === 'whatsapp') q = q.eq('can_whatsapp', true);
  if (f.city) q = q.ilike('city', f.city);
  if (f.source) q = q.eq('source', f.source);
  if (f.specialization) q = q.ilike('specialization', f.specialization);
  if (f.uncontacted === '1') q = q.is('last_contacted_at', null);
  if (f.paying === '1') q = q.eq('pagando_hoy', true);
  if (f.warming === '1') {
    const cutoff = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString();
    q = q.gt('engagement_score', 0).gte('last_engaged_at', cutoff);
  }
  if (f.list) q = q.eq('lead_list_members.list_id', f.list);
  if (f.quality === 'no_email') q = q.or('email.is.null,email.eq.""');
  if (f.quality === 'no_phone') q = q.or('phone.is.null,phone.eq.""');
  if (f.quality === 'bad_phone') q = q.not('phone', 'is', null).neq('phone', '').not('phone', 'match', E164_SQL_REGEX);
  if (f.quality === 'no_name') q = q.or('full_name.is.null,full_name.eq."",full_name.eq.Desconocido');
  return q;
}

export function filterFromSearchParams(sp: Record<string, string | undefined>): LeadsFilter {
  return {
    q: sp.q,
    segment: sp.segment,
    stage: sp.stage,
    channel: sp.channel,
    warming: sp.warming,
    city: sp.city,
    source: sp.source,
    specialization: sp.specialization,
    uncontacted: sp.uncontacted,
    paying: sp.paying,
    list: sp.list,
    quality: sp.quality,
  };
}
