-- =====================================================================
-- Migración: Discovery v1-compat (Fase 1)
-- Fecha:     2026-06-29 15:00
-- Objetivo:  Soportar el rediseño del wizard (SEMANAL / MONEDA LOCAL /
--            enums nuevos) SIN recalibrar el score ni mover umbrales.
--            El frontend ya traduce a valores canónicos vía un adapter;
--            esta migración añade una capa DEFENSIVA server-side que
--            normaliza (con PARIDAD exacta a esos adapter maps) cualquier
--            valor nuevo conocido que llegue al top-level, registra
--            warnings controlados para valores desconocidos (evitando el
--            ELSE=>0 silencioso), y persiste las nuevas señales de
--            diagnóstico/CTA.
--
-- Propiedades:
--   * IDEMPOTENTE: CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS.
--   * BACKWARD-COMPATIBLE: para entradas CANÓNICAS el score, segmento,
--     clasificación y breakdown son EXACTAMENTE iguales a hoy y la
--     función calculate_discovery_score devuelve el MISMO jsonb (sin
--     claves extra). El overload legacy posicional NO se toca.
--   * NO aplica datos, NO despliega edge functions, NO hace commits.
-- =====================================================================


-- =====================================================================
-- 1) NORMALIZADOR DEFENSIVO DE INPUTS DE SCORE
--    Paridad EXACTA con los adapter maps del frontend. Devuelve los seis
--    valores normalizados a canónicos + un array `warnings` con cada key
--    cuyo valor NO es canónico NI mapeable (desconocido). Los valores NULL
--    no generan warning (significan "no respondido").
-- =====================================================================
CREATE OR REPLACE FUNCTION public.normalize_discovery_score_inputs(
  p_vol     text,
  p_lost    text,
  p_intent  text,
  p_urgency text,
  p_ticket  text,
  p_digital text
) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $fn$
DECLARE
  v_vol     text;
  v_lost    text;
  v_intent  text;
  v_urgency text;
  v_ticket  text;
  v_digital text;
  v_warn    text[] := ARRAY[]::text[];

  -- Conjuntos canónicos aceptados hoy por calculate_discovery_score
  c_vol     CONSTANT text[] := ARRAY['lt_30','30_80','81_150','151_300','gt_300'];
  c_lost    CONSTANT text[] := ARRAY['0_2','3_5','6_10','11_20','gt_20','no_medido'];
  c_intent  CONSTANT text[] := ARRAY['información','demo','probar','solo_ver'];
  c_urgency CONSTANT text[] := ARRAY['alta','media','baja'];
  c_ticket  CONSTANT text[] := ARRAY['lt_10','10_25','25_50','50_100','gt_100','variable'];
  c_digital CONSTANT text[] := ARRAY['papel','llamadas','sin_sistema','whatsapp','excel','software_basico','software_avanzado'];
BEGIN
  -- ---- VOLUMEN (adapter: weekly_* -> canónico) ----------------------
  IF p_vol IS NULL THEN
    v_vol := NULL;
  ELSIF p_vol = ANY (c_vol) THEN
    v_vol := p_vol;                       -- ya canónico: passthrough
  ELSE
    v_vol := CASE p_vol
      WHEN 'weekly_lt_15'    THEN '30_80'
      WHEN 'weekly_15_50'    THEN '81_150'
      WHEN 'weekly_51_100'   THEN 'gt_300'
      WHEN 'weekly_100_plus' THEN 'gt_300'
      ELSE NULL END;
    IF v_vol IS NULL THEN
      v_vol  := p_vol;                    -- desconocido: se conserva crudo
      v_warn := array_append(v_warn, 'vol');
    END IF;
  END IF;

  -- ---- CITAS PERDIDAS (adapter: weekly_* -> canónico) ---------------
  IF p_lost IS NULL THEN
    v_lost := NULL;
  ELSIF p_lost = ANY (c_lost) THEN
    v_lost := p_lost;                     -- incluye 'no_medido' (canónico)
  ELSE
    v_lost := CASE p_lost
      WHEN 'weekly_none'    THEN '0_2'
      WHEN 'weekly_1_2'     THEN '6_10'
      WHEN 'weekly_3_5'     THEN '11_20'
      WHEN 'weekly_6_10'    THEN 'gt_20'
      WHEN 'weekly_10_plus' THEN 'gt_20'
      ELSE NULL END;
    IF v_lost IS NULL THEN
      v_lost := p_lost;
      v_warn := array_append(v_warn, 'lost');
    END IF;
  END IF;

  -- ---- INTENCIÓN (sin adapter: solo canónico) ----------------------
  IF p_intent IS NULL THEN
    v_intent := NULL;
  ELSIF p_intent = ANY (c_intent) THEN
    v_intent := p_intent;
  ELSE
    v_intent := p_intent;
    v_warn   := array_append(v_warn, 'intent');
  END IF;

  -- ---- URGENCIA (sin adapter: solo canónico) -----------------------
  IF p_urgency IS NULL THEN
    v_urgency := NULL;
  ELSIF p_urgency = ANY (c_urgency) THEN
    v_urgency := p_urgency;
  ELSE
    v_urgency := p_urgency;
    v_warn    := array_append(v_warn, 'urgency');
  END IF;

  -- ---- TICKET (el adapter ya deriva el bucket USD; solo canónico) ---
  IF p_ticket IS NULL THEN
    v_ticket := NULL;
  ELSIF p_ticket = ANY (c_ticket) THEN
    v_ticket := p_ticket;
  ELSE
    v_ticket := p_ticket;
    v_warn   := array_append(v_warn, 'ticket');
  END IF;

  -- ---- MÉTODO DE AGENDA (adapter: scheduling_method -> canónico) ----
  IF p_digital IS NULL THEN
    v_digital := NULL;
  ELSIF p_digital = ANY (c_digital) THEN
    v_digital := p_digital;               -- whatsapp/excel/papel/software_* canónicos
  ELSE
    v_digital := CASE p_digital
      WHEN 'digital_calendar'    THEN 'software_basico'
      WHEN 'scheduling_software' THEN 'software_basico'
      WHEN 'external_portal'     THEN 'software_basico'
      WHEN 'clinical_system'     THEN 'software_avanzado'
      WHEN 'institution_system'  THEN 'software_avanzado'
      WHEN 'not_centralized'     THEN 'sin_sistema'
      ELSE NULL END;
    IF v_digital IS NULL THEN
      v_digital := p_digital;
      v_warn    := array_append(v_warn, 'digital');
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'vol',      v_vol,
    'lost',     v_lost,
    'intent',   v_intent,
    'urgency',  v_urgency,
    'ticket',   v_ticket,
    'digital',  v_digital,
    'warnings', to_jsonb(v_warn)          -- text[] -> array json de strings
  );
END;
$fn$;

ALTER FUNCTION public.normalize_discovery_score_inputs(text, text, text, text, text, text) OWNER TO postgres;

-- normalize es invocada por calculate_discovery_score (SECURITY INVOKER,
-- expuesta a anon/authenticated/service_role). Garantizamos EXECUTE explícito
-- para que la ruta del invocador no falle aunque el entorno revoque el
-- EXECUTE por defecto de PUBLIC.
GRANT EXECUTE ON FUNCTION public.normalize_discovery_score_inputs(text, text, text, text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.normalize_discovery_score_inputs(text, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_discovery_score_inputs(text, text, text, text, text, text) TO service_role;


-- =====================================================================
-- 2) SCORE: mismos pesos/umbrales, pero normalizando primero.
--    Para entradas CANÓNICAS el resultado es idéntico al actual (mismo
--    jsonb, sin claves extra). Si la normalización produjo warnings, se
--    añaden las claves 'warnings' y 'normalized_inputs' al jsonb de salida.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.calculate_discovery_score(
  p_q_volume  text,
  p_q_lost    text,
  p_q_intent  text,
  p_q_urgency text,
  p_q_ticket  text,
  p_q_digital text
) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $fn$
DECLARE
  -- Inputs ya normalizados a canónico (capa defensiva)
  v_norm  jsonb := public.normalize_discovery_score_inputs(
                     p_q_volume, p_q_lost, p_q_intent, p_q_urgency, p_q_ticket, p_q_digital);
  n_vol   text := v_norm->>'vol';
  n_lost  text := v_norm->>'lost';
  n_int   text := v_norm->>'intent';
  n_urg   text := v_norm->>'urgency';
  n_tick  text := v_norm->>'ticket';
  n_dig   text := v_norm->>'digital';
  v_warn  jsonb := COALESCE(v_norm->'warnings', '[]'::jsonb);

  v_vol   integer := 0;
  v_lost  integer := 0;
  v_int   integer := 0;
  v_urg   integer := 0;
  v_tick  integer := 0;
  v_dig   integer := 0;
  v_total integer;
  v_seg   text;
  v_cls   text;
  v_action text;
  v_out   jsonb;
BEGIN
  -- Factor 1: Volumen (0-25) — espeja scoring.js midpoints
  v_vol := CASE n_vol
    WHEN 'gt_300'   THEN 25
    WHEN '151_300'  THEN 20
    WHEN '81_150'   THEN 13
    WHEN '30_80'    THEN 6
    WHEN 'lt_30'    THEN 2
    ELSE 0 END;

  -- Factor 2: Citas perdidas (0-20) — midpoints: 0_2→1, 3_5→4, 6_10→8, 11_20→15, gt_20→25
  v_lost := CASE n_lost
    WHEN 'no_medido' THEN 6
    WHEN 'gt_20'     THEN 20
    WHEN '11_20'     THEN 16
    WHEN '6_10'      THEN 12
    WHEN '3_5'       THEN 8
    WHEN '0_2'       THEN 2
    ELSE 0 END;

  -- Factor 3: Intención (0-20)
  v_int := CASE n_int
    WHEN 'demo'        THEN 20
    WHEN 'probar'      THEN 15
    WHEN 'información' THEN 8
    WHEN 'solo_ver'    THEN 3
    ELSE 0 END;

  -- Factor 4: Urgencia (0-15) — ya debe venir canonicalizado (alta|media|baja)
  v_urg := CASE n_urg
    WHEN 'alta'  THEN 15
    WHEN 'media' THEN 8
    WHEN 'baja'  THEN 2
    ELSE 0 END;

  -- Factor 5: Ticket (0-10) — midpoints: lt_10→8, 10_25→18, 25_50→38, 50_100→75, gt_100→120, variable→50
  v_tick := CASE n_tick
    WHEN 'gt_100'  THEN 10
    WHEN '50_100'  THEN 8
    WHEN '25_50'   THEN 5
    WHEN 'variable' THEN 5
    WHEN '10_25'   THEN 3
    WHEN 'lt_10'   THEN 1
    ELSE 0 END;

  -- Factor 6: Método de agenda (0-10)
  v_dig := CASE
    WHEN n_dig IN ('papel','llamadas','sin_sistema')    THEN 10
    WHEN n_dig IN ('whatsapp','excel')                  THEN 7
    WHEN n_dig = 'software_basico'                       THEN 3
    WHEN n_dig = 'software_avanzado'                     THEN 1
    ELSE 0 END;

  v_total := LEAST(100, v_vol + v_lost + v_int + v_urg + v_tick + v_dig);

  -- Segmento y clasificación (umbrales SIN cambios)
  v_seg    := CASE WHEN v_total >= 75 THEN 'SUPER_HOT'
                   WHEN v_total >= 50 THEN 'HOT'
                   WHEN v_total >= 25 THEN 'WARM'
                   ELSE 'COLD' END;
  v_cls    := CASE WHEN v_total >= 75 THEN 'sql_caliente'
                   WHEN v_total >= 50 THEN 'mql'
                   WHEN v_total >= 25 THEN 'lead_tibio'
                   ELSE 'lead_frio' END;
  v_action := CASE WHEN v_total >= 50 THEN 'contactar_whatsapp'
                   WHEN v_total >= 25 THEN 'nutrir'
                   ELSE 'enviar_guia' END;

  -- Salida BASE: idéntica a la actual (mismas claves, mismo orden)
  v_out := jsonb_build_object(
    'score',               v_total,
    'segment',             v_seg,
    'lead_classification', v_cls,
    'recommended_action',  v_action,
    'breakdown', jsonb_build_object(
      'volume', v_vol, 'lost', v_lost, 'intent', v_int,
      'urgency', v_urg, 'ticket', v_tick, 'digital', v_dig
    )
  );

  -- Solo si hubo valores no canónicos: exponer trazabilidad SIN romper
  -- compatibilidad (entradas canónicas => warnings vacío => sin claves extra).
  IF jsonb_array_length(v_warn) > 0 THEN
    v_out := v_out
      || jsonb_build_object('warnings', v_warn)
      || jsonb_build_object('normalized_inputs', jsonb_build_object(
            'volume', n_vol, 'lost', n_lost, 'intent', n_int,
            'urgency', n_urg, 'ticket', n_tick, 'digital', n_dig
         ));
  END IF;

  RETURN v_out;
END;
$fn$;

ALTER FUNCTION public.calculate_discovery_score(text, text, text, text, text, text) OWNER TO postgres;


-- =====================================================================
-- 3) NUEVAS COLUMNAS EN discovery_leads (señales de diagnóstico / CTA /
--    score legacy / debug de normalización).
-- =====================================================================
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS legacy_lead_score   integer;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS scoring_version     text;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS risk_dominant       text;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS risk_evidence       jsonb;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS main_pain           text;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS main_pains          jsonb;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS recommended_action  text;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS primary_cta_key     text;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS primary_cta_label   text;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS selected_currency   text;
ALTER TABLE public.discovery_leads ADD COLUMN IF NOT EXISTS score_input_debug   jsonb;

COMMENT ON COLUMN public.discovery_leads.legacy_lead_score  IS 'Score v1-compat (== score). Se conserva como legacy; no se recalibra.';
COMMENT ON COLUMN public.discovery_leads.scoring_version    IS 'Versión de scoring; default discovery_v1_compat.';
COMMENT ON COLUMN public.discovery_leads.score_input_debug  IS 'Trazabilidad: {received, normalized, warnings} de la normalización defensiva de inputs de score.';
COMMENT ON COLUMN public.discovery_leads.risk_evidence      IS 'Evidencia del riesgo dominante (jsonb) tomada de findings->risk_evidence.';
COMMENT ON COLUMN public.discovery_leads.selected_currency  IS 'Moneda seleccionada (frontend_calculations->currency->selected_currency).';


-- =====================================================================
-- 4) NUEVAS COLUMNAS EN leads_master (señales comerciales de CTA).
--    Según HECHOS confirmados ambas faltan; se crean idempotentes.
-- =====================================================================
ALTER TABLE public.leads_master ADD COLUMN IF NOT EXISTS commercial_intent text;
ALTER TABLE public.leads_master ADD COLUMN IF NOT EXISTS cta_intent        text;

COMMENT ON COLUMN public.leads_master.commercial_intent IS 'Intención comercial derivada de CTA (p.ej. high) cuando llega cta_clicked.';
COMMENT ON COLUMN public.leads_master.cta_intent        IS 'Intención específica del CTA: activate_trial|recover_spaces|reduce_whatsapp|configure_agenda.';


-- =====================================================================
-- 5) submit_discovery_lead(input jsonb): igual que hoy, PERO añade la
--    capa defensiva de normalización, persiste score legacy + señales de
--    diagnóstico/CTA y guarda score_input_debug. NO cambia el encolado WA
--    ni el no-downgrade de marketing_segment. Mantiene EXCEPTION WHEN OTHERS.
--    Hardening: SET search_path (todas las referencias ya van schema-
--    cualificadas o son builtins, => comportamiento idéntico, cero
--    regresión) para blindar la función SECURITY DEFINER.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.submit_discovery_lead("input" jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_workspace_id  CONSTANT uuid := 'e2096477-fa6a-4b8f-a8b3-bd46ad720167';
  v_score_result  jsonb;
  v_discovery_id  uuid;
  v_lead_id       uuid;
  v_queue_id      uuid;
  v_template_key  text;

  v_full_name     text := trim(input->>'name');
  v_whatsapp      text := trim(input->>'whatsapp_e164');
  v_email         text := nullif(trim(input->>'email'), '');
  v_city          text := nullif(trim(input->>'city'), '');
  v_clinic        text := nullif(trim(input->>'clinic_name'), '');
  v_country       text := COALESCE(nullif(trim(input->>'phone_country_iso2'),''), 'CO');
  v_consent       boolean := COALESCE((input->>'consent')::boolean, false);

  v_q_volume      text := input->>'monthly_appointments_range';
  v_q_lost        text := input->>'lost_appointments_range';
  v_q_intent      text := input->>'desired_next_step';
  v_q_urgency     text;
  v_q_ticket      text := input->>'average_ticket_range';
  v_q_digital     text := input->>'scheduling_method';

  v_fe            jsonb := COALESCE(input->'frontend_calculations', '{}'::jsonb);
  v_findings      jsonb := COALESCE(input->'findings', '{}'::jsonb);
  v_maturity      text;
  v_annual_lost   numeric;
  v_hidden_cost   numeric;
  v_segment       text;

  -- v1-compat: normalización defensiva + persistencia de señales nuevas
  v_norm            jsonb;
  v_warnings        jsonb;
  v_score_input_dbg jsonb;
  v_scoring_version text;
  v_event_meta      jsonb;
BEGIN
  IF v_full_name IS NULL OR v_full_name = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Nombre requerido');
  END IF;
  IF v_whatsapp IS NULL OR v_whatsapp !~ '^\+[1-9][0-9]{7,14}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Teléfono inválido. Formato E.164 requerido (+573001234567)');
  END IF;
  IF NOT v_consent THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Consentimiento requerido');
  END IF;

  v_q_urgency := CASE
    WHEN (input->>'urgency') LIKE 'media%' THEN 'media'
    ELSE COALESCE(input->>'urgency', 'baja')
  END;

  v_maturity    := COALESCE(v_findings->>'agenda_maturity_level', v_fe->>'agenda_maturity_level');
  v_annual_lost := (COALESCE(v_findings->>'annual_lost_revenue', v_fe->>'annual_lost_revenue'))::numeric;
  v_hidden_cost := (COALESCE(v_findings->>'hidden_cost_total',   v_fe->>'hidden_cost_total'))::numeric;

  -- ---- Capa defensiva: normalizar inputs de score y armar debug ------
  v_norm     := public.normalize_discovery_score_inputs(
                  v_q_volume, v_q_lost, v_q_intent, v_q_urgency, v_q_ticket, v_q_digital);
  v_warnings := COALESCE(v_norm->'warnings', '[]'::jsonb);

  v_score_input_dbg := jsonb_build_object(
    'received', jsonb_build_object(
      'vol', v_q_volume, 'lost', v_q_lost, 'intent', v_q_intent,
      'urgency', v_q_urgency, 'ticket', v_q_ticket, 'digital', v_q_digital
    ),
    'normalized', jsonb_build_object(
      'vol', v_norm->>'vol', 'lost', v_norm->>'lost', 'intent', v_norm->>'intent',
      'urgency', v_norm->>'urgency', 'ticket', v_norm->>'ticket', 'digital', v_norm->>'digital'
    ),
    'warnings', v_warnings
  );

  v_scoring_version := COALESCE(input->>'scoring_version', 'discovery_v1_compat');

  -- calculate_discovery_score normaliza de nuevo internamente (idempotente);
  -- el resultado para inputs canónicos es idéntico al histórico.
  v_score_result := public.calculate_discovery_score(
    v_q_volume, v_q_lost, v_q_intent, v_q_urgency, v_q_ticket, v_q_digital
  );

  v_segment := v_score_result->>'segment';

  SELECT id INTO v_lead_id
  FROM public.leads_master
  WHERE workspace_id = v_workspace_id AND phone = v_whatsapp
  LIMIT 1;

  IF v_lead_id IS NULL THEN
    INSERT INTO public.leads_master (
      workspace_id, full_name, phone, email, specialization, city, country,
      marketing_segment, recovery_score, can_whatsapp, can_email,
      pipeline_stage, source, referral_campaign, whatsapp_opted_in
    ) VALUES (
      v_workspace_id,
      v_full_name,
      v_whatsapp,
      v_email,
      nullif(trim(input->>'specialty'), ''),
      v_city,
      v_country,
      v_segment,
      (v_score_result->>'score')::integer,
      true,
      v_email IS NOT NULL,
      'new',
      'discovery_form',
      COALESCE(input->>'utm_campaign', 'discovery_form'),
      true
    )
    RETURNING id INTO v_lead_id;
  ELSE
    UPDATE public.leads_master SET
      full_name          = v_full_name,
      email              = COALESCE(v_email, email),
      city               = COALESCE(v_city, city),
      recovery_score     = GREATEST(recovery_score, (v_score_result->>'score')::integer),
      marketing_segment  = CASE
        WHEN ARRAY_POSITION(ARRAY['COLD','WARM','HOT','SUPER_HOT']::text[], v_segment)
           > ARRAY_POSITION(ARRAY['COLD','WARM','HOT','SUPER_HOT']::text[], marketing_segment)
        THEN v_segment
        ELSE marketing_segment END,
      can_whatsapp       = true,
      whatsapp_opted_in  = true,
      updated_at         = now()
    WHERE id = v_lead_id;
  END IF;

  INSERT INTO public.discovery_leads (
    workspace_id,         lead_id,
    full_name,            whatsapp_e164,         email,
    city,                 country,               clinic_name,
    consent,              preferred_contact_channel,
    q_volume,             q_lost,                q_intent,
    q_urgency,            q_ticket,              q_digital,
    monthly_appointments_range, scheduling_method,
    average_ticket_range, lost_appointments_range,
    urgency,              desired_next_step,
    raw_answers,
    score,                marketing_segment,     score_breakdown,
    lead_classification,  calculation_version,
    agenda_maturity_level, annual_lost_revenue,  hidden_cost_total,
    findings,             frontend_calculations,
    completion_rate,      started_at,
    utm_source,           utm_medium,            utm_campaign,
    utm_content,          utm_term,              landing_url,
    -- v1-compat: nuevas columnas
    legacy_lead_score,    scoring_version,       score_input_debug,
    risk_dominant,        risk_evidence,
    recommended_action,
    main_pain,            main_pains,
    selected_currency,
    primary_cta_key,      primary_cta_label
  ) VALUES (
    v_workspace_id,       v_lead_id,
    v_full_name,          v_whatsapp,            v_email,
    v_city,               v_country,             v_clinic,
    v_consent,            'whatsapp',
    v_q_volume,           v_q_lost,              v_q_intent,
    v_q_urgency,          v_q_ticket,            v_q_digital,
    v_q_volume,           v_q_digital,
    v_q_ticket,           v_q_lost,
    v_q_urgency,          v_q_intent,
    COALESCE(input->'raw_answers', input->'raw_payload', '{}'::jsonb),
    (v_score_result->>'score')::integer,
    v_segment,
    v_score_result->'breakdown',
    v_score_result->>'lead_classification',
    'v2',
    v_maturity,           v_annual_lost,         v_hidden_cost,
    v_findings,           v_fe,
    (input->>'completion_rate')::numeric,
    (input->>'started_at')::timestamptz,
    input->>'utm_source',  input->>'utm_medium',  input->>'utm_campaign',
    input->>'utm_content', input->>'utm_term',
    COALESCE(input->>'page_url', 'https://discovery.appril.co'),
    -- v1-compat: valores nuevos
    (v_score_result->>'score')::integer,                       -- legacy_lead_score == score (no recalibrado)
    v_scoring_version,                                          -- scoring_version
    v_score_input_dbg,                                          -- score_input_debug {received,normalized,warnings}
    v_findings->>'risk_dominant',                              -- risk_dominant
    v_findings->'risk_evidence',                               -- risk_evidence (jsonb)
    v_score_result->>'recommended_action',                     -- recommended_action
    input->>'main_pain',                                       -- main_pain
    input->'main_pains',                                       -- main_pains (jsonb)
    v_fe->'currency'->>'selected_currency',                    -- selected_currency
    input->>'primary_cta_key',                                 -- primary_cta_key
    input->>'primary_cta_label'                                -- primary_cta_label
  )
  RETURNING id INTO v_discovery_id;

  -- Metadata del evento de submit; añade warnings de score si los hubo.
  v_event_meta := jsonb_build_object(
    'discovery_lead_id', v_discovery_id,
    'score',             v_score_result->>'score',
    'segment',           v_segment,
    'classification',    v_score_result->>'lead_classification',
    'maturity',          v_maturity,
    'scoring_version',   v_scoring_version,
    'utm_campaign',      input->>'utm_campaign',
    'utm_source',        input->>'utm_source'
  )
  || CASE WHEN jsonb_array_length(v_warnings) > 0
          THEN jsonb_build_object('score_warnings', v_warnings)
          ELSE '{}'::jsonb END;

  INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
  VALUES (
    v_workspace_id, v_lead_id,
    'discovery_form_submitted', 'funnel',
    v_event_meta
  );

  -- Elegir template WA según segmento (SIN cambios)
  v_template_key := CASE v_segment
    WHEN 'SUPER_HOT' THEN 'super_hot_intro_wa'
    WHEN 'HOT'       THEN 'hot_followup_wa'
    ELSE                  'warm_wa_if_opened'   -- WARM y COLD: misma plantilla
  END;

  -- Encolar mensaje WA (inmediato, scheduled_at = now()) (SIN cambios)
  INSERT INTO public.message_queue (
    workspace_id, lead_id, template_key, channel,
    to_address, payload, status, scheduled_at
  ) VALUES (
    v_workspace_id,
    v_lead_id,
    v_template_key,
    'whatsapp',
    v_whatsapp,
    jsonb_build_object('full_name', split_part(v_full_name, ' ', 1)),
    'pending',
    now()
  )
  RETURNING id INTO v_queue_id;

  INSERT INTO public.lead_events (workspace_id, lead_id, event_type, event_channel, metadata)
  VALUES (
    v_workspace_id, v_lead_id,
    'message_queued', 'whatsapp',
    jsonb_build_object(
      'message_queue_id', v_queue_id,
      'template_key',     v_template_key,
      'discovery_lead_id', v_discovery_id
    )
  );

  RETURN jsonb_build_object(
    'ok',                  true,
    'discovery_lead_id',   v_discovery_id,
    'lead_id',             v_lead_id,
    'lead_score',          (v_score_result->>'score')::integer,
    'legacy_lead_score',   (v_score_result->>'score')::integer,
    'scoring_version',     v_scoring_version,
    'lead_classification', v_score_result->>'lead_classification',
    'marketing_segment',   v_segment,
    'agenda_maturity_level', v_maturity,
    'recommended_action',  v_score_result->>'recommended_action',
    'annual_lost_revenue', v_annual_lost,
    'annual_admin_hours',  (v_fe->>'annual_admin_hours')::numeric,
    'admin_cost_annual',   (v_fe->>'admin_cost_annual')::numeric,
    'hidden_cost_total',   v_hidden_cost,
    'queued_message_id',   v_queue_id,
    'template_key',        v_template_key,
    'score_warnings',      v_warnings,
    'scheduled_at',        now()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$_$;

ALTER FUNCTION public.submit_discovery_lead(jsonb) OWNER TO postgres;

-- =====================================================================
-- FIN migración Discovery v1-compat (Fase 1)
-- =====================================================================
