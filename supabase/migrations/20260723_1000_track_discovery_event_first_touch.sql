-- DEC-023 gate (a): atribución por dl desde el PRIMER toque, no solo al submit.
--
-- Antes: track_discovery_event solo espejaba a lead_events los eventos tardíos
-- (contact_submitted, result_viewed, ...) y únicamente si el frontend ya conocía
-- lead_id — que antes del submit es siempre null. Un lead real que hacía click en
-- el email (dl en la URL) y abandonaba antes del submit era INVISIBLE en
-- lead_events (caso dominante del lote HOT 30: 3 clicks reales → 0 rastro).
--
-- Ahora:
--   1. El input acepta `dl` y `page_url` (el frontend los envía desde tracking.js).
--   2. Si no llega lead_id pero sí dl, se resuelve contra leads_master.dl_token
--      (la misma identidad que usa submit_discovery_lead).
--   3. discovery_page_view y discovery_started se espejan a lead_events cuando el
--      lead está resuelto, con dedupe de 24h por lead+evento (los refresh de página
--      no ensucian el timeline).
--   4. dl y page_url quedan en metadata de discovery_events y del lead_event.
--
-- Compatibilidad: input sin dl = comportamiento anterior intacto. CREATE OR REPLACE
-- preserva los grants existentes (anon sigue pudiendo ejecutar: funnel público,
-- dejado abierto a propósito en el barrido del 14-jul).

CREATE OR REPLACE FUNCTION public.track_discovery_event(input jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_workspace_id      CONSTANT uuid := 'e2096477-fa6a-4b8f-a8b3-bd46ad720167';
  v_event_name        text := input->>'event_name';
  v_anon_session      text := trim(input->>'anonymous_session_id');
  v_discovery_lead_id uuid := (input->>'discovery_lead_id')::uuid;
  v_lead_id           uuid := (input->>'lead_id')::uuid;
  v_dl                text := nullif(trim(input->>'dl'), '');
  v_page_url          text := nullif(trim(input->>'page_url'), '');
  v_dl_resolved       boolean := false;
  v_discovery_event_id uuid;
  v_lead_event_id      uuid;

  v_allowed text[] := ARRAY[
    'discovery_page_view','discovery_started',
    'question_viewed','question_answered',
    'gift_viewed','section_completed',
    'contact_form_viewed','contact_submitted',
    'result_viewed','cta_clicked',
    'discovery_abandoned','discovery_pdf_generated',
    'discovery_message_queued','discovery_queue_skipped'
  ];
  -- Eventos que se espejan a lead_events cuando hay lead resuelto.
  -- discovery_page_view y discovery_started (primer toque) llevan dedupe 24h.
  v_crm_events text[] := ARRAY[
    'discovery_page_view','discovery_started',
    'contact_submitted','result_viewed','cta_clicked',
    'discovery_abandoned','discovery_pdf_generated',
    'discovery_message_queued','discovery_queue_skipped'
  ];
  v_first_touch_events CONSTANT text[] := ARRAY['discovery_page_view','discovery_started'];
BEGIN
  IF v_event_name IS NULL OR NOT (v_event_name = ANY(v_allowed)) THEN
    RETURN jsonb_build_object('ok',false,'error',
      format('event_name inválido: "%s"', COALESCE(v_event_name,'null')));
  END IF;
  IF v_anon_session IS NULL OR v_anon_session = '' THEN
    RETURN jsonb_build_object('ok',false,'error','anonymous_session_id requerido');
  END IF;

  -- Identidad por dl (primer toque): misma resolución que submit_discovery_lead
  IF v_lead_id IS NULL AND v_dl IS NOT NULL THEN
    SELECT id INTO v_lead_id FROM public.leads_master
     WHERE workspace_id = v_workspace_id AND dl_token = v_dl LIMIT 1;
    v_dl_resolved := v_lead_id IS NOT NULL;
  END IF;

  INSERT INTO public.discovery_events (
    workspace_id, anonymous_session_id, discovery_lead_id, lead_id, event_name,
    section, section_index, step_key, step_index, question_key,
    answer_value, answer_label, cta_key, cta_label, progress_percent,
    time_on_step_ms, elapsed_ms, metadata,
    utm_source, utm_medium, utm_campaign, utm_content, utm_term,
    device_type, landing_variant
  ) VALUES (
    v_workspace_id, v_anon_session, v_discovery_lead_id, v_lead_id, v_event_name,
    input->>'section',          (input->>'section_index')::integer,
    input->>'step_key',         (input->>'step_index')::integer,
    input->>'question_key',
    input->>'answer_value',     input->>'answer_label',
    input->>'cta_key',          input->>'cta_label',
    (input->>'progress_percent')::numeric,
    (input->>'time_on_step_ms')::integer,
    (input->>'elapsed_ms')::integer,
    COALESCE(input->'metadata', '{}'::jsonb)
      || jsonb_strip_nulls(jsonb_build_object('dl', v_dl, 'page_url', v_page_url)),
    input->>'utm_source',  input->>'utm_medium',  input->>'utm_campaign',
    input->>'utm_content', input->>'utm_term',
    input->>'device_type', input->>'landing_variant'
  )
  RETURNING id INTO v_discovery_event_id;

  IF v_lead_id IS NOT NULL AND v_event_name = ANY(v_crm_events) THEN
    -- Dedupe 24h SOLO para los eventos de primer toque: un refresh o una segunda
    -- visita en el día no duplican el timeline del lead.
    IF NOT (v_event_name = ANY(v_first_touch_events))
       OR NOT EXISTS (
         SELECT 1 FROM public.lead_events
          WHERE workspace_id = v_workspace_id
            AND lead_id = v_lead_id
            AND event_type = v_event_name
            AND created_at > now() - interval '24 hours'
       )
    THEN
      INSERT INTO public.lead_events (
        workspace_id, lead_id, event_type, event_channel, event_value, metadata
      ) VALUES (
        v_workspace_id, v_lead_id, v_event_name, 'funnel',
        COALESCE(input->>'cta_key', input->>'lead_classification', input->>'step_key'),
        jsonb_strip_nulls(jsonb_build_object(
          'discovery_event_id',   v_discovery_event_id,
          'anonymous_session_id', v_anon_session,
          'discovery_lead_id',    v_discovery_lead_id,
          'dl',                   v_dl,
          'dl_resolved',          CASE WHEN v_dl_resolved THEN true ELSE NULL END,
          'page_url',             v_page_url,
          'score',                input->>'lead_score',
          'segment',              input->>'marketing_segment',
          'cta_key',              input->>'cta_key',
          'progress_percent',     input->>'progress_percent',
          'utm_campaign',         input->>'utm_campaign',
          'utm_source',           input->>'utm_source'
        ))
      )
      RETURNING id INTO v_lead_event_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',true,
    'discovery_event_id', v_discovery_event_id,
    'lead_event_id',      v_lead_event_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'error',SQLERRM);
END;
$function$;
