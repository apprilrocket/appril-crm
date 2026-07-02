-- Appril CRM — Watchdog de salud de los agentes de WhatsApp
-- Capa 1 (pasiva, SQL puro): detecta wa_reply sin respuesta del agente, cola
--   atascada y rachas de fallos — 0 tokens LLM.
-- Capa 2 (canario activo, pg_net): llama GET ?health=1 de ambos agentes
--   (CRM hwiocriejizjdqqcfrsj y producto gfpdrqqsaqifyepvmwpt) cada tick.
-- Capa 3 (alerta): encola UN email por message_queue (pipeline existente del
--   sender) hacia el dueño, con dedupe de 30 min. Tokens solo si un humano/
--   agente decide diagnosticar después.
-- Cron: cada 10 min vía pg_cron (agent_health_tick).

-- ── Incidentes ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_health_incidents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  uuid NOT NULL DEFAULT 'e2096477-fa6a-4b8f-a8b3-bd46ad720167',
  source        text NOT NULL,              -- crm_wa_agent | product_wa_agent | message_queue | canary
  incident_type text NOT NULL,              -- wa_no_reply | queue_stuck | queue_overdue | send_failures | canary_down | canary_degraded
  ref_id        text,                       -- id del evento/mensaje que originó el incidente (dedupe)
  details       jsonb DEFAULT '{}'::jsonb,
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open','notified','resolved','ignored')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  notified_at   timestamptz,
  resolved_at   timestamptz
);

-- Dedupe: un solo incidente abierto/notificado por (source, tipo, ref).
CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_health_open
  ON public.agent_health_incidents (source, incident_type, coalesce(ref_id, ''))
  WHERE status IN ('open','notified');

ALTER TABLE public.agent_health_incidents ENABLE ROW LEVEL SECURITY;

-- ── Canario: registro de requests pg_net pendientes de recolectar ───────────
CREATE TABLE IF NOT EXISTS public.agent_health_canary_requests (
  request_id bigint PRIMARY KEY,            -- id devuelto por net.http_get
  source     text NOT NULL,                 -- crm_wa_agent | product_wa_agent
  fired_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_health_canary_requests ENABLE ROW LEVEL SECURITY;

-- ── Lead de sistema (message_queue.lead_id es NOT NULL) ─────────────────────
INSERT INTO public.leads_master (workspace_id, full_name, email, marketing_segment, can_email)
SELECT 'e2096477-fa6a-4b8f-a8b3-bd46ad720167', 'Sistema — Alertas Appril', 'system-alerts@appril.co', 'COLD', true
WHERE NOT EXISTS (SELECT 1 FROM public.leads_master WHERE email = 'system-alerts@appril.co');

-- ── Template del email de alerta (canal del sender existente) ────────────────
INSERT INTO public.message_templates (workspace_id, template_key, name, description, channel, subject, html_body, text_body, status, variables)
SELECT
  'e2096477-fa6a-4b8f-a8b3-bd46ad720167',
  'agent_health_alert',
  'Alerta interna — salud de agentes WA',
  'Email interno del watchdog de agentes. No es marketing; no tocar desde campañas.',
  'email',
  '🔴 Appril — {{incident_count}} incidente(s) en agentes WhatsApp',
  '<h2 style="color:#F45B69;margin:0 0 12px;">Watchdog Appril</h2><p>Se detectaron <b>{{incident_count}}</b> incidente(s):</p><pre style="background:#f8fafc;padding:12px;border-radius:8px;font-size:13px;white-space:pre-wrap;">{{summary}}</pre><p style="color:#64748b;font-size:13px;">Detalle: tabla <code>agent_health_incidents</code> del Supabase del CRM. Diagnóstico: pídele a Claude Code «revisa los incidentes de salud de los agentes».</p>',
  E'Watchdog Appril — {{incident_count}} incidente(s):\n\n{{summary}}\n\nDetalle en agent_health_incidents (Supabase CRM).',
  'active',
  '["incident_count","summary"]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM public.message_templates WHERE template_key = 'agent_health_alert');

-- ── Config: destino de alertas y URLs del canario ────────────────────────────
INSERT INTO public.app_config (key, value) VALUES
  ('agent_health_alert_email', 'mauricio@todoc.co'),
  ('agent_health_canary_crm_url', 'https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/whatsapp-agent?health=1'),
  ('agent_health_canary_product_url', 'https://gfpdrqqsaqifyepvmwpt.supabase.co/functions/v1/whatsapp-agent?health=1')
ON CONFLICT (key) DO NOTHING;

-- ── Capa 1: watchdog pasivo ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.agent_health_scan() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- 1) wa_reply sin wa_agent_reply del mismo lead en >5 min (ventana 5-30 min;
  --    se ignoran leads con agente pausado o handoff humano).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'crm_wa_agent', 'wa_no_reply', e.id::text,
         jsonb_build_object('lead_id', e.lead_id, 'reply_at', e.created_at)
  FROM lead_events e
  JOIN leads_master l ON l.id = e.lead_id
  WHERE e.event_type = 'wa_reply'
    AND e.created_at BETWEEN now() - interval '30 minutes' AND now() - interval '5 minutes'
    AND l.agent_paused = false
    AND NOT EXISTS (
      SELECT 1 FROM lead_events r
      WHERE r.lead_id = e.lead_id
        AND r.event_type = 'wa_agent_reply'
        AND r.created_at >= e.created_at
    )
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 2) Mensajes atascados en sending >10 min (bug conocido del sender).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'message_queue', 'queue_stuck', q.id::text,
         jsonb_build_object('template_key', q.template_key, 'channel', q.channel, 'updated_at', q.updated_at)
  FROM message_queue q
  WHERE q.status = 'sending' AND q.updated_at < now() - interval '10 minutes'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 3) Pendientes vencidos >15 min (el cron del sender corre cada 2 min).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'message_queue', 'queue_overdue', q.id::text,
         jsonb_build_object('template_key', q.template_key, 'channel', q.channel, 'scheduled_at', q.scheduled_at)
  FROM message_queue q
  WHERE q.status = 'pending' AND q.scheduled_at < now() - interval '15 minutes'
    AND q.template_key <> 'agent_health_alert'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- 4) Racha de fallos de envío: >=3 errores en 20 min (un incidente por franja).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT 'message_queue', 'send_failures', to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24:00'),
         jsonb_build_object('errors_20min', c.n)
  FROM (SELECT count(*) AS n FROM message_attempts
        WHERE status <> 'success' AND started_at > now() - interval '20 minutes') c
  WHERE c.n >= 3
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- Auto-resolución: wa_no_reply cuya respuesta llegó después; stuck/overdue ya drenados.
  UPDATE agent_health_incidents i SET status = 'resolved', resolved_at = now()
  WHERE i.status IN ('open','notified') AND i.incident_type = 'wa_no_reply'
    AND EXISTS (
      SELECT 1 FROM lead_events r
      WHERE r.lead_id = (i.details->>'lead_id')::uuid
        AND r.event_type = 'wa_agent_reply'
        AND r.created_at >= (i.details->>'reply_at')::timestamptz
    );

  UPDATE agent_health_incidents i SET status = 'resolved', resolved_at = now()
  WHERE i.status IN ('open','notified') AND i.incident_type IN ('queue_stuck','queue_overdue')
    AND NOT EXISTS (
      SELECT 1 FROM message_queue q
      WHERE q.id::text = i.ref_id AND q.status IN ('sending','pending')
    );
END $$;

-- ── Capa 2: canario activo (pg_net es asíncrono → fire en un tick, collect al siguiente) ──
CREATE OR REPLACE FUNCTION public.agent_health_canary_fire() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid bigint; u text;
BEGIN
  SELECT value INTO u FROM app_config WHERE key = 'agent_health_canary_crm_url';
  IF u IS NOT NULL THEN
    SELECT net.http_get(url := u, timeout_milliseconds := 8000) INTO rid;
    INSERT INTO agent_health_canary_requests (request_id, source) VALUES (rid, 'crm_wa_agent');
  END IF;
  SELECT value INTO u FROM app_config WHERE key = 'agent_health_canary_product_url';
  IF u IS NOT NULL THEN
    SELECT net.http_get(url := u, timeout_milliseconds := 8000) INTO rid;
    INSERT INTO agent_health_canary_requests (request_id, source) VALUES (rid, 'product_wa_agent');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.agent_health_canary_collect() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Respuestas llegadas: no-200 o ok:false → incidente (ref = franja horaria para dedupe).
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT cr.source,
         CASE WHEN r.status_code IS DISTINCT FROM 200 THEN 'canary_down' ELSE 'canary_degraded' END,
         cr.source || ':' || to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24:00'),
         jsonb_build_object('status_code', r.status_code, 'body', left(r.content, 500))
  FROM agent_health_canary_requests cr
  JOIN net._http_response r ON r.id = cr.request_id
  WHERE r.status_code IS DISTINCT FROM 200
     OR (r.content_type LIKE 'application/json%' AND (r.content::jsonb->>'ok') = 'false')
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- Requests sin respuesta tras 20 min = timeout/función caída.
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT cr.source, 'canary_down',
         cr.source || ':timeout:' || to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24:00'),
         jsonb_build_object('fired_at', cr.fired_at, 'note', 'sin respuesta de pg_net en 20 min')
  FROM agent_health_canary_requests cr
  LEFT JOIN net._http_response r ON r.id = cr.request_id
  WHERE r.id IS NULL AND cr.fired_at < now() - interval '20 minutes'
  ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;

  -- Limpieza: recolectados o vencidos.
  DELETE FROM agent_health_canary_requests cr
  WHERE EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = cr.request_id)
     OR cr.fired_at < now() - interval '25 minutes';
END $$;

-- ── Capa 3: alerta por email (reusa message_queue → sender → SES) ────────────
CREATE OR REPLACE FUNCTION public.agent_health_notify() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_lead uuid; v_email text; v_count int; v_summary text;
BEGIN
  SELECT count(*) INTO v_count FROM agent_health_incidents WHERE status = 'open';
  IF v_count = 0 THEN RETURN; END IF;

  -- Dedupe: máx 1 alerta cada 30 min.
  IF EXISTS (
    SELECT 1 FROM message_queue
    WHERE template_key = 'agent_health_alert' AND created_at > now() - interval '30 minutes'
  ) THEN RETURN; END IF;

  SELECT string_agg(format('[%s] %s — %s (ref %s)', i.source, i.incident_type,
                           coalesce(i.details::text, ''), coalesce(i.ref_id, '-')), E'\n')
  INTO v_summary
  FROM (SELECT * FROM agent_health_incidents WHERE status = 'open' ORDER BY created_at LIMIT 15) i;

  SELECT id INTO v_lead FROM leads_master WHERE email = 'system-alerts@appril.co' LIMIT 1;
  SELECT value INTO v_email FROM app_config WHERE key = 'agent_health_alert_email';
  IF v_lead IS NULL OR v_email IS NULL THEN RETURN; END IF;

  INSERT INTO message_queue (workspace_id, lead_id, template_key, channel, to_address, payload, triggered_by)
  VALUES ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', v_lead, 'agent_health_alert', 'email', v_email,
          jsonb_build_object('incident_count', v_count, 'summary', v_summary),
          'agent_health_watchdog');

  UPDATE agent_health_incidents SET status = 'notified', notified_at = now() WHERE status = 'open';
END $$;

-- ── Tick maestro y cron ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.agent_health_tick() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM agent_health_canary_collect();  -- recolecta respuestas del tick anterior
  PERFORM agent_health_scan();            -- watchdog pasivo
  PERFORM agent_health_notify();          -- alerta si hay abiertos
  PERFORM agent_health_canary_fire();     -- dispara el canario para el próximo tick
END $$;

SELECT cron.schedule('agent-health-tick', '*/10 * * * *', $$SELECT public.agent_health_tick()$$);
