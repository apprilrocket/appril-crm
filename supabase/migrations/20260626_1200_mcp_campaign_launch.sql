-- ════════════════════════════════════════════════════════════════════════════
-- MCP de campañas — capa canónica de lanzamiento + gate de aprobación humana
-- ════════════════════════════════════════════════════════════════════════════
-- Aditivo y de bajo riesgo: agrega columnas nullable y funciones nuevas.
-- NO modifica la lógica existente del CRM (actions.ts sigue funcionando igual).
--
-- Modelo de aprobación (decisión: "el envío masivo SIEMPRE requiere humano"):
--   1. La IA (MCP) crea la campaña en 'draft' y opcionalmente la PROGRAMA
--      (scheduled_at + launch_requested_at). Sigue en 'draft'.
--   2. Un HUMANO la aprueba: set approved_at/approved_by + status='scheduled'.
--   3. El scheduler (crm_run_due_campaigns, vía pg_cron) lanza SOLO campañas
--      'scheduled' + approved_at != null + scheduled_at <= now().
--   El MCP nunca setea approved_at ni status='running'/'scheduled'.
-- ════════════════════════════════════════════════════════════════════════════

-- 1) Columnas de aprobación ---------------------------------------------------
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS approved_at        timestamptz,
  ADD COLUMN IF NOT EXISTS approved_by        uuid,
  ADD COLUMN IF NOT EXISTS launch_requested_at timestamptz;

COMMENT ON COLUMN public.campaigns.approved_at IS
  'Aprobación humana para envío masivo. El scheduler NO lanza sin esto.';
COMMENT ON COLUMN public.campaigns.launch_requested_at IS
  'Momento en que el MCP/IA dejó la campaña lista y pidió aprobación.';

-- 2) Preview de audiencia (misma lógica que el lanzamiento) -------------------
--    Devuelve audiencia total y elegibles tras guardas de canal.
CREATE OR REPLACE FUNCTION public.crm_preview_audience(
  p_workspace_id   uuid,
  p_channel        text,
  p_segments       text[],
  p_list_ids       uuid[],
  p_allow_no_optin boolean DEFAULT false
) RETURNS TABLE(audience bigint, eligible bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH base AS (
    SELECT l.*
    FROM leads_master l
    WHERE l.workspace_id = p_workspace_id
      AND (coalesce(array_length(p_segments,1),0) = 0 OR l.marketing_segment = ANY(p_segments))
      AND (coalesce(array_length(p_list_ids,1),0) = 0 OR EXISTS (
            SELECT 1 FROM lead_list_members m
            WHERE m.lead_id = l.id AND m.list_id = ANY(p_list_ids)))
  )
  SELECT
    (SELECT count(*) FROM base) AS audience,
    (SELECT count(*) FROM base b WHERE
        (p_channel = 'email'
          AND b.can_email AND b.email IS NOT NULL AND b.email LIKE '%@%')
        OR
        (p_channel = 'whatsapp'
          AND b.can_whatsapp AND b.phone IS NOT NULL
          AND b.phone ~ '^\+[1-9][0-9]{7,14}$'
          AND ((p_allow_no_optin) OR b.whatsapp_opted_in))
    ) AS eligible;
$$;

-- 3) Lanzamiento canónico (fuente única de verdad del enqueue) ----------------
--    Espejo exacto de launchCampaign (src/app/campaigns/actions.ts) en SQL.
--    Exige approved_at != null → no hay envío sin aprobación humana.
CREATE OR REPLACE FUNCTION public.crm_launch_campaign(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c              campaigns%ROWTYPE;
  v_template     text;
  v_segments     text[];
  v_list_ids     uuid[];
  v_require_optin boolean;
  v_scheduled    timestamptz;
  v_audience     bigint;
  v_queued       bigint;
BEGIN
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','campaign_not_found'); END IF;
  IF c.approved_at IS NULL THEN
    RETURN jsonb_build_object('error','not_approved',
      'detail','Falta aprobación humana (campaigns.approved_at)');
  END IF;
  IF c.status NOT IN ('scheduled','draft') THEN
    RETURN jsonb_build_object('error','bad_status','status',c.status);
  END IF;

  v_template := c.template_keys[1];
  IF v_template IS NULL THEN RETURN jsonb_build_object('error','no_template'); END IF;

  v_segments := coalesce(
    (SELECT array_agg(x) FROM jsonb_array_elements_text(c.segment_filter->'marketing_segment') x), '{}');
  v_list_ids := coalesce(
    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(c.segment_filter->'list_ids') x), '{}');
  v_require_optin := (c.channel = 'whatsapp')
    AND coalesce((c.segment_filter->>'allow_no_optin')::boolean, false) = false;
  v_scheduled := coalesce(c.scheduled_at, now());

  SELECT count(*) INTO v_audience
  FROM leads_master l
  WHERE l.workspace_id = c.workspace_id
    AND (coalesce(array_length(v_segments,1),0) = 0 OR l.marketing_segment = ANY(v_segments))
    AND (coalesce(array_length(v_list_ids,1),0) = 0 OR EXISTS (
          SELECT 1 FROM lead_list_members m WHERE m.lead_id = l.id AND m.list_id = ANY(v_list_ids)));

  WITH eligible AS (
    SELECT l.*
    FROM leads_master l
    WHERE l.workspace_id = c.workspace_id
      AND (coalesce(array_length(v_segments,1),0) = 0 OR l.marketing_segment = ANY(v_segments))
      AND (coalesce(array_length(v_list_ids,1),0) = 0 OR EXISTS (
            SELECT 1 FROM lead_list_members m WHERE m.lead_id = l.id AND m.list_id = ANY(v_list_ids)))
      AND (
        (c.channel = 'email'
          AND l.can_email AND l.email IS NOT NULL AND l.email LIKE '%@%')
        OR
        (c.channel = 'whatsapp'
          AND l.can_whatsapp AND l.phone IS NOT NULL
          AND l.phone ~ '^\+[1-9][0-9]{7,14}$'
          AND ((NOT v_require_optin) OR l.whatsapp_opted_in))
      )
  )
  INSERT INTO message_queue
    (workspace_id, lead_id, campaign_id, template_key, channel, to_address, payload, triggered_by, scheduled_at, status)
  SELECT
    c.workspace_id, e.id, c.id, v_template, c.channel,
    CASE WHEN c.channel = 'email' THEN e.email ELSE regexp_replace(e.phone, '^\+', '') END,
    jsonb_build_object('full_name', coalesce(e.full_name, 'Doctor')),
    'campaign', v_scheduled, 'pending'
  FROM eligible e;
  GET DIAGNOSTICS v_queued = ROW_COUNT;

  UPDATE campaigns SET
    status = 'running',
    started_at = now(),
    stats = jsonb_build_object(
      'total', v_queued, 'queued', v_queued, 'sent', 0, 'failed', 0,
      'audience', v_audience, 'excluded', greatest(0, v_audience - v_queued),
      'optin_required', v_require_optin)
  WHERE id = p_campaign_id;

  RETURN jsonb_build_object(
    'queued', v_queued, 'audience', v_audience,
    'excluded', greatest(0, v_audience - v_queued));
END $$;

-- 4) Scheduler: lanza campañas vencidas y aprobadas ---------------------------
--    Construido pero NO programado. Para activar el auto-lanzamiento:
--      SELECT cron.schedule('crm-campaign-scheduler','* * * * *',
--        $$SELECT public.crm_run_due_campaigns()$$);
CREATE OR REPLACE FUNCTION public.crm_run_due_campaigns()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT id FROM campaigns
    WHERE status = 'scheduled' AND approved_at IS NOT NULL AND scheduled_at <= now()
    ORDER BY scheduled_at
  LOOP
    PERFORM crm_launch_campaign(r.id);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Permisos: estas funciones se invocan con service_role (MCP/scheduler).
REVOKE ALL ON FUNCTION public.crm_launch_campaign(uuid) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.crm_run_due_campaigns() FROM anon, authenticated;
