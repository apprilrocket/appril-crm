-- ═══════════════════════════════════════════════════════════════════════════
-- Watchdog de salud — Capa 1 (auto-recuperación) + Capa 2 (aviso legible por
-- WhatsApp con prompt para pegar en Claude Code). 16-jul-2026.
--
-- Antes: el watchdog solo mandaba un email a admin@appril.co con un volcado
-- crudo (details::text) — ilegible y a un buzón que nadie mira en el momento.
--
-- Ahora:
--   • Capa 1 (agent_health_autofix): ANTES del scan, recupera los mensajes
--     atascados en 'sending' (bug clásico) con queue_recover_stuck. Si arregla
--     algo, deja un incidente 'auto_recovered' (verde) para informarlo.
--   • Capa 2 (agent_health_notify): además del email de respaldo, arma un
--     payload legible (rojo = necesita acción, verde = ya resuelto) y lo manda
--     por pg_net al Edge `health-alert` del PRODUCTO, que lo redacta en español
--     claro + un prompt corto y lo envía por WhatsApp al número personal de
--     Mauricio (por el asistente del doctor, donde la ventana de 24h suele estar
--     abierta). El prompt apunta al id del incidente: Mauricio lo pega aquí y
--     Claude saca el detalle y lo arregla.
--
-- El aviso NUNCA lleva errores crudos: el Edge traduce cada incident_type a una
-- frase clara. Config en app_config (edge_url + número WhatsApp); el secreto
-- compartido se siembra por fuera de git.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Capa 1: auto-recuperación determinística ────────────────────────────────
CREATE OR REPLACE FUNCTION public.agent_health_autofix()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_recovered int;
BEGIN
  -- Devuelve a 'pending' los mensajes huérfanos en 'sending' (>10 min), antes de
  -- que el scan los registre como incidente. Los que agotaron intentos → 'failed'.
  v_recovered := queue_recover_stuck(10, 3);

  -- Si de verdad recuperó algo, lo informamos en verde (deduplicado a 15 min).
  IF v_recovered > 0
     AND NOT EXISTS (
       SELECT 1 FROM agent_health_incidents
       WHERE incident_type = 'auto_recovered' AND status = 'open'
         AND created_at > now() - interval '15 minutes'
     ) THEN
    INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
    VALUES ('autofix', 'auto_recovered',
            'queue_recover:' || to_char(date_trunc('minute', now()), 'YYYY-MM-DD HH24:MI'),
            jsonb_build_object(
              'note', format('Reencolé %s mensaje(s) que estaban atascados en la cola de envío. Ya están saliendo.', v_recovered),
              'count', v_recovered))
    ON CONFLICT (source, incident_type, coalesce(ref_id, '')) WHERE status IN ('open','notified') DO NOTHING;
  END IF;
END $function$;

-- ── Capa 2: aviso legible por WhatsApp + email de respaldo ───────────────────
CREATE OR REPLACE FUNCTION public.agent_health_notify()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_lead uuid; v_email text; v_count int; v_summary text;
  v_edge text; v_secret text; v_wa text;
  v_red jsonb; v_green jsonb;
BEGIN
  SELECT count(*) INTO v_count FROM agent_health_incidents WHERE status = 'open';
  IF v_count = 0 THEN RETURN; END IF;

  -- Guarda de tanda: máximo un aviso cada 30 min (agrupa incidentes).
  IF EXISTS (
    SELECT 1 FROM message_queue
    WHERE template_key = 'agent_health_alert' AND created_at > now() - interval '30 minutes'
  ) THEN RETURN; END IF;

  -- Resumen crudo para el email de respaldo.
  SELECT string_agg(format('[%s] %s — %s (ref %s)', i.source, i.incident_type,
                           coalesce(i.details::text, ''), coalesce(i.ref_id, '-')), E'\n')
  INTO v_summary
  FROM (SELECT * FROM agent_health_incidents WHERE status = 'open' ORDER BY created_at LIMIT 15) i;

  -- Payload legible para WhatsApp.
  SELECT jsonb_agg(jsonb_build_object('id', i.id, 'source', i.source,
                                      'incident_type', i.incident_type, 'details', i.details))
  INTO v_red
  FROM (SELECT * FROM agent_health_incidents
        WHERE status = 'open' AND incident_type <> 'auto_recovered'
        ORDER BY created_at LIMIT 15) i;

  SELECT jsonb_agg(i.details->>'note') INTO v_green
  FROM agent_health_incidents
  WHERE status = 'open' AND incident_type = 'auto_recovered';

  -- Email de respaldo (comportamiento previo, intacto).
  SELECT id INTO v_lead FROM leads_master WHERE email = 'system-alerts@appril.co' LIMIT 1;
  SELECT value INTO v_email FROM app_config WHERE key = 'agent_health_alert_email';
  IF v_lead IS NOT NULL AND v_email IS NOT NULL THEN
    INSERT INTO message_queue (workspace_id, lead_id, template_key, channel, to_address, payload, triggered_by)
    VALUES ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', v_lead, 'agent_health_alert', 'email', v_email,
            jsonb_build_object('incident_count', v_count, 'summary', v_summary),
            'agent_health_watchdog');
  END IF;

  -- WhatsApp legible al número personal, vía el Edge del producto (best-effort).
  SELECT value INTO v_edge   FROM app_config WHERE key = 'agent_health_alert_edge_url';
  SELECT value INTO v_secret FROM app_config WHERE key = 'agent_health_alert_secret';
  SELECT value INTO v_wa     FROM app_config WHERE key = 'agent_health_alert_wa';
  IF v_edge IS NOT NULL AND v_secret IS NOT NULL AND v_wa IS NOT NULL THEN
    PERFORM net.http_post(
      url     := v_edge,
      body    := jsonb_build_object('secret', v_secret, 'to', v_wa,
                                    'red', coalesce(v_red, '[]'::jsonb),
                                    'green', coalesce(v_green, '[]'::jsonb)),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 8000);
  END IF;

  -- Los rojos quedan 'notified' (siguen vivos hasta resolverse); los verdes ya
  -- están arreglados → 'resolved'.
  UPDATE agent_health_incidents SET status = 'notified', notified_at = now()
  WHERE status = 'open' AND incident_type <> 'auto_recovered';
  UPDATE agent_health_incidents SET status = 'resolved', resolved_at = now()
  WHERE status = 'open' AND incident_type = 'auto_recovered';
END $function$;

-- ── Orquestación del tick: autofix ANTES del scan ───────────────────────────
CREATE OR REPLACE FUNCTION public.agent_health_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM agent_health_canary_collect();
  PERFORM agent_health_autofix();   -- Capa 1: recuperar atascados antes del scan
  PERFORM agent_health_scan();
  PERFORM agent_health_notify();    -- Capa 2: avisar legible + prompt por WhatsApp
  PERFORM agent_health_canary_fire();
END $function$;

-- ── Config no-secreta (el secreto compartido se siembra por fuera de git) ────
UPDATE app_config SET value = 'https://gfpdrqqsaqifyepvmwpt.supabase.co/functions/v1/health-alert'
  WHERE key = 'agent_health_alert_edge_url';
INSERT INTO app_config (key, value)
  SELECT 'agent_health_alert_edge_url', 'https://gfpdrqqsaqifyepvmwpt.supabase.co/functions/v1/health-alert'
  WHERE NOT EXISTS (SELECT 1 FROM app_config WHERE key = 'agent_health_alert_edge_url');

UPDATE app_config SET value = '573103716567' WHERE key = 'agent_health_alert_wa';
INSERT INTO app_config (key, value)
  SELECT 'agent_health_alert_wa', '573103716567'
  WHERE NOT EXISTS (SELECT 1 FROM app_config WHERE key = 'agent_health_alert_wa');
