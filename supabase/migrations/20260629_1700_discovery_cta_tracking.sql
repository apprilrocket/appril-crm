-- ════════════════════════════════════════════════════════════════════════════
-- Discovery · Tracking de CTA → señales comerciales para el agente WhatsApp
-- ════════════════════════════════════════════════════════════════════════════
-- El frontend de Discovery (appril-discovery) llama a este RPC ANTES de redirigir
-- al lead a WhatsApp (o a otro destino). Persiste:
--   1. Un evento auditable cta_clicked en lead_events (funnel) con metadata completa.
--   2. Señales comerciales en leads_master (commercial_intent, cta_intent) para que
--      el whatsapp-agent las lea como contexto cuando el lead escriba.
--   3. primary_cta_key/label en discovery_leads si aún no estaban.
--
-- SECURITY DEFINER + EXECUTE a anon: el frontend es anónimo. Se identifica el lead
-- por discovery_lead_id (UUID no adivinable). Idempotencia: no se exige (varios
-- clicks son señal válida); cada click es un evento. Aditivo, no destructivo.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.track_discovery_cta(
  p_discovery_lead_id uuid,
  p_cta_key           text,
  p_cta_label         text default null,
  p_destination       text default 'whatsapp_agent',
  p_source            text default 'discovery_result',
  p_session_id        text default null
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public','pg_temp'
AS $$
declare
  v_ws         uuid;
  v_lead       uuid;
  v_risk       text;
  v_seg        text;
  v_cur        text;
  v_intent     text;
  v_commercial text;
begin
  if p_discovery_lead_id is null or coalesce(btrim(p_cta_key),'') = '' then
    return jsonb_build_object('ok', false, 'error', 'discovery_lead_id y cta_key requeridos');
  end if;

  select workspace_id, lead_id, risk_dominant, marketing_segment, selected_currency
    into v_ws, v_lead, v_risk, v_seg, v_cur
  from public.discovery_leads
  where id = p_discovery_lead_id;

  if v_lead is null then
    return jsonb_build_object('ok', false, 'error', 'discovery_lead no encontrado');
  end if;

  -- Mapear cta_key → cta_intent canónico (alineado con el comentario de la columna).
  v_intent := case p_cta_key
    when 'activate_trial'   then 'activate_trial'
    when 'recover_spaces'   then 'recover_spaces'
    when 'reduce_whatsapp'  then 'reduce_whatsapp'
    when 'configure_agenda' then 'configure_agenda'
    when 'whatsapp'         then 'activate_trial'
    else p_cta_key
  end;

  -- Intención comercial: alta si va al agente WA o es un CTA de activación.
  v_commercial := case
    when p_destination = 'whatsapp_agent'
      or p_cta_key in ('activate_trial','whatsapp','recover_spaces') then 'high'
    else 'medium'
  end;

  insert into public.lead_events (workspace_id, lead_id, event_type, event_channel, event_value, metadata)
  values (
    v_ws, v_lead, 'cta_clicked', 'funnel', p_cta_key,
    jsonb_build_object(
      'discovery_lead_id', p_discovery_lead_id,
      'cta_key',           p_cta_key,
      'cta_label',         p_cta_label,
      'destination',       p_destination,
      'source',            p_source,
      'session_id',        p_session_id,
      'risk_dominant',     v_risk,
      'marketing_segment', v_seg,
      'selected_currency', v_cur,
      'lead_id',           v_lead
    )
  );

  update public.leads_master
     set commercial_intent = v_commercial,
         cta_intent        = v_intent,
         last_engaged_at   = now(),
         updated_at        = now()
   where id = v_lead;

  update public.discovery_leads
     set primary_cta_key   = coalesce(primary_cta_key, p_cta_key),
         primary_cta_label = coalesce(primary_cta_label, p_cta_label)
   where id = p_discovery_lead_id;

  return jsonb_build_object(
    'ok', true,
    'lead_id', v_lead,
    'cta_intent', v_intent,
    'commercial_intent', v_commercial
  );

exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

ALTER FUNCTION public.track_discovery_cta(uuid,text,text,text,text,text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.track_discovery_cta(uuid,text,text,text,text,text) TO anon;
GRANT EXECUTE ON FUNCTION public.track_discovery_cta(uuid,text,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.track_discovery_cta(uuid,text,text,text,text,text) TO service_role;
