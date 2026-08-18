-- ============================================================================
-- Repara el watchdog de salud de los agentes WA (CRM) — caído desde 2026-07-17
-- ============================================================================
--
-- INCIDENTE: `agent-health-tick` acumuló 4.646 fallos consecutivos desde el
-- 2026-07-17 07:00 UTC (144/144 en 24h, 0 éxitos). `agent_health_incidents`
-- quedó con 173 filas, TODAS `resolved`: 0 abiertas. Eso se leía como "todo
-- verde" durante 32 días.
--
-- CAUSA RAÍZ: en `agent_health_notify()` el agregado de `v_green` usa el alias
-- `i` sin declararlo en el FROM → `missing FROM-clause entry for table "i"`.
-- Introducido por `20260716_2000_watchdog_autofix_wa_alert.sql`.
--
-- BUCLE CERRADO (probado en prod): `agent_health_canary_requests` conservaba 2
-- filas CONGELADAS en 2026-07-17T07:00:00.153338Z. Cada tick: (1) collect las
-- ve sin respuesta y >20 min → inserta 2 `canary_down`; (2) notify revienta;
-- (3) rollback de TODA la transacción → se pierden los incidentes Y el DELETE
-- de esas filas → vuelta a empezar. Por eso `canary_fire` (el check
-- `anthropic_ok`, creado tras el incidente del 12-jul de saldo agotado) llevaba
-- 32 días sin ejercitarse, y `autofix`/`queue_recover_stuck` tampoco corría.
--
-- Revisada adversarialmente por `appril-data-expert` (veredicto: aplicar con
-- cambios). Sus hallazgos B1/A1/A2/M1/M2/M3 están incorporados abajo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) Limpieza del residuo del rollback  [A2]
-- ---------------------------------------------------------------------------
-- Las 2 filas congeladas: sus respuestas en net._http_response ya fueron
-- purgadas, así que la rama "timeout" de collect las reportaría como 2
-- `canary_down` FALSOS en el primer tick sano — un email + un WhatsApp diciendo
-- que ambos asistentes dejaron de responder, justo cuando más hay que confiar
-- en la señal. Es el mismo DELETE que hace collect al final; solo se adelanta.
DELETE FROM public.agent_health_canary_requests
WHERE fired_at < now() - interval '25 minutes';

-- ---------------------------------------------------------------------------
-- 1) EL FIX: alias `i` en el agregado verde
-- ---------------------------------------------------------------------------
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

  IF EXISTS (
    SELECT 1 FROM message_queue
    WHERE template_key = 'agent_health_alert' AND created_at > now() - interval '30 minutes'
  ) THEN RETURN; END IF;

  SELECT string_agg(format('[%s] %s — %s (ref %s)', i.source, i.incident_type,
                           coalesce(i.details::text, ''), coalesce(i.ref_id, '-')), E'\n')
  INTO v_summary
  FROM (SELECT * FROM agent_health_incidents WHERE status = 'open' ORDER BY created_at LIMIT 15) i;

  SELECT jsonb_agg(jsonb_build_object('id', i.id, 'source', i.source,
                                      'incident_type', i.incident_type, 'details', i.details))
  INTO v_red
  FROM (SELECT * FROM agent_health_incidents
        WHERE status = 'open' AND incident_type <> 'auto_recovered'
        ORDER BY created_at LIMIT 15) i;

  -- FIX 2026-08-18: faltaba el alias `i`. Sin él la función abortaba SIEMPRE
  -- que hubiera algún incidente abierto, y con ella la transacción entera.
  SELECT jsonb_agg(i.details->>'note') INTO v_green
  FROM agent_health_incidents i
  WHERE i.status = 'open' AND i.incident_type = 'auto_recovered';

  SELECT id INTO v_lead FROM leads_master WHERE email = 'system-alerts@appril.co' LIMIT 1;
  SELECT value INTO v_email FROM app_config WHERE key = 'agent_health_alert_email';
  IF v_lead IS NOT NULL AND v_email IS NOT NULL THEN
    INSERT INTO message_queue (workspace_id, lead_id, template_key, channel, to_address, payload, triggered_by)
    VALUES ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', v_lead, 'agent_health_alert', 'email', v_email,
            jsonb_build_object('incident_count', v_count, 'summary', v_summary),
            'agent_health_watchdog');
  END IF;

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

  UPDATE agent_health_incidents SET status = 'notified', notified_at = now()
  WHERE status = 'open' AND incident_type <> 'auto_recovered';
  UPDATE agent_health_incidents SET status = 'resolved', resolved_at = now()
  WHERE status = 'open' AND incident_type = 'auto_recovered';
END $function$;

-- ---------------------------------------------------------------------------
-- 2) Aislar el AVISO de la DETECCIÓN  [M1, M2]
-- ---------------------------------------------------------------------------
-- `autofix`, `notify` y `canary_fire` (efectos secundarios) van cada uno en su
-- BEGIN/EXCEPTION: un fallo al AVISAR ya no puede tumbar lo que `scan` detectó.
-- `canary_collect` y `scan` (la DETECCIÓN) siguen propagando A PROPÓSITO: si
-- fallan, la corrida debe quedar `failed` para que el selfcheck del punto 3 la
-- vea. `canary_fire` se aísla porque, siendo el ÚLTIMO paso, un fallo suyo
-- revertía todo lo detectado — la misma forma exacta del bug del 17-jul.
CREATE OR REPLACE FUNCTION public.agent_health_tick()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_err text; v_notify_ok boolean := false;
BEGIN
  PERFORM agent_health_canary_collect();

  BEGIN
    PERFORM agent_health_autofix();
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    RAISE WARNING 'agent_health_autofix fallo: %', v_err;
  END;

  PERFORM agent_health_scan();

  BEGIN
    PERFORM agent_health_notify();
    v_notify_ok := true;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    RAISE WARNING 'agent_health_notify fallo: %', v_err;
    INSERT INTO agent_health_incidents (source, incident_type, ref_id, details, status)
    VALUES ('canary', 'watchdog_notify_failed', NULL,
            jsonb_build_object('error', v_err,
                               'note', 'El watchdog detecta pero no puede avisar'),
            'open')
    ON CONFLICT (source, incident_type, coalesce(ref_id, ''))
      WHERE status IN ('open','notified') DO NOTHING;
  END;

  -- M2: si notify volvió a funcionar, cerrar el aviso anterior. Sin esto la fila
  -- queda 'notified' para siempre y la guarda ON CONFLICT silenciaría TODA falla
  -- futura de notify.
  IF v_notify_ok THEN
    UPDATE agent_health_incidents SET status = 'resolved', resolved_at = now()
     WHERE incident_type = 'watchdog_notify_failed' AND status IN ('open','notified');
  END IF;

  BEGIN
    PERFORM agent_health_canary_fire();
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    RAISE WARNING 'agent_health_canary_fire fallo: %', v_err;
    INSERT INTO agent_health_incidents (source, incident_type, ref_id, details, status)
    VALUES ('canary', 'watchdog_canary_failed',
            to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24:00'),
            jsonb_build_object('error', v_err, 'note', 'El canario no pudo dispararse'),
            'open')
    ON CONFLICT (source, incident_type, coalesce(ref_id, ''))
      WHERE status IN ('open','notified') DO NOTHING;
  END;
END $function$;

-- ---------------------------------------------------------------------------
-- 3) Vigilar al vigilante  [B1, A1, M3]
-- ---------------------------------------------------------------------------
-- Nada vigilaba al watchdog: por eso 32 días de silencio se leyeron como salud.
-- NO depende del camino roto (no usa agent_health_notify). Cada hora al minuto
-- :07 (el tick corre */10, así que no colisiona y el de :00 lleva 7 min).
-- Hacen falta ~6 ticks fallidos seguidos para alertar → sin ruido por un fallo
-- aislado.
CREATE OR REPLACE FUNCTION public.agent_health_selfcheck()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ultima_ok timestamptz;
  v_fallos int; v_err text;
  v_edge text; v_secret text; v_wa text;
  v_id uuid; v_ref text; v_lead uuid; v_email text;
BEGIN
  -- `cron.job` tiene RLS por `username`. Al ser SECURITY DEFINER, current_user
  -- es el OWNER (verificado 18-ago: owner=postgres y el job corre como postgres,
  -- así que coinciden). Si algún día dejaran de coincidir, el SELECT devolvería
  -- 0 filas SIN error y concluiríamos "watchdog caído" para siempre: un falso
  -- positivo permanente en el canal más crítico. Fallamos RUIDOSAMENTE.
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'agent-health-tick') THEN
    RAISE EXCEPTION
      'agent_health_selfcheck: no veo el job agent-health-tick en cron.job (current_user=%). Revisar owner/RLS.',
      current_user;
  END IF;

  SELECT max(d.start_time) INTO v_ultima_ok
  FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'agent-health-tick' AND d.status = 'succeeded';

  IF v_ultima_ok IS NOT NULL AND v_ultima_ok > now() - interval '1 hour' THEN
    UPDATE agent_health_incidents SET status = 'resolved', resolved_at = now()
     WHERE incident_type = 'watchdog_down' AND status IN ('open','notified');
    RETURN;
  END IF;

  SELECT count(*), left(max(d.return_message), 200) INTO v_fallos, v_err
  FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
  WHERE j.jobname = 'agent-health-tick' AND d.status = 'failed'
    AND d.start_time > now() - interval '24 hours';

  IF EXISTS (SELECT 1 FROM agent_health_incidents
             WHERE incident_type = 'watchdog_down'
               AND created_at > now() - interval '6 hours') THEN
    RETURN;
  END IF;

  -- B1 (BLOQUEANTE que cazó la revisión): con ref_id NULL la clave del índice
  -- parcial uq_agent_health_open sería constante y, como NADIE resuelve
  -- watchdog_down, el 2º aviso (a las 6h) reventaría con 23505 y el selfcheck
  -- enmudecería PARA SIEMPRE justo durante la caída. Se particiona por hora.
  v_ref := 'watchdog:' || to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24:00');

  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details, status, notified_at)
  VALUES ('canary', 'watchdog_down', v_ref,
          jsonb_build_object('ultima_corrida_ok', v_ultima_ok, 'fallos_24h', v_fallos,
                             'error', v_err,
                             'note', 'El monitor de salud (agent-health-tick) no esta corriendo'),
          'notified', now())
  ON CONFLICT (source, incident_type, coalesce(ref_id, ''))
    WHERE status IN ('open','notified') DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN RETURN; END IF;

  -- M3: respaldo por email. El WhatsApp es best-effort (ventana de 24h de Meta;
  -- la plantilla `alerta_salud_es` sigue pendiente), y esta es LA alerta que no
  -- se puede perder. Mismo patrón que agent_health_notify.
  SELECT id INTO v_lead FROM leads_master WHERE email = 'system-alerts@appril.co' LIMIT 1;
  SELECT value INTO v_email FROM app_config WHERE key = 'agent_health_alert_email';
  IF v_lead IS NOT NULL AND v_email IS NOT NULL THEN
    INSERT INTO message_queue (workspace_id, lead_id, template_key, channel, to_address, payload, triggered_by)
    VALUES ('e2096477-fa6a-4b8f-a8b3-bd46ad720167', v_lead, 'agent_health_alert', 'email', v_email,
            jsonb_build_object('incident_count', 1,
              'summary', format('[canary] watchdog_down — el cron agent-health-tick no corre. Ultima corrida OK: %s. Fallos 24h: %s. Error: %s',
                                coalesce(v_ultima_ok::text,'nunca'), v_fallos, coalesce(v_err,'-'))),
            'agent_health_watchdog');
  END IF;

  SELECT value INTO v_edge   FROM app_config WHERE key = 'agent_health_alert_edge_url';
  SELECT value INTO v_secret FROM app_config WHERE key = 'agent_health_alert_secret';
  SELECT value INTO v_wa     FROM app_config WHERE key = 'agent_health_alert_wa';
  IF v_edge IS NOT NULL AND v_secret IS NOT NULL AND v_wa IS NOT NULL THEN
    PERFORM net.http_post(
      url  := v_edge,
      body := jsonb_build_object('secret', v_secret, 'to', v_wa,
                -- A1: el Edge hace red.map(r => r.id) para armar el prompt; sin
                -- `id` el WhatsApp diría "el incidente de salud undefined".
                'red', jsonb_build_array(jsonb_build_object(
                  'id', v_id, 'source', 'canary', 'incident_type', 'watchdog_down',
                  'details', jsonb_build_object('fallos_24h', v_fallos,
                                                'ultima_corrida_ok', v_ultima_ok,
                                                'error', v_err))),
                'green', '[]'::jsonb),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 8000);
  END IF;
END $function$;

REVOKE ALL ON FUNCTION public.agent_health_selfcheck() FROM PUBLIC, anon, authenticated;

-- Higiene: `agent_health_autofix` nació el 17-jul, DESPUÉS del barrido de grants
-- del 14-jul, y conservaba EXECUTE para PUBLIC y anon (ACL verificada hoy:
-- `=X/postgres,...,anon=X/postgres`). Es SECURITY DEFINER y dispara
-- queue_recover_stuck: misma familia que el barrido cerró. Se cierra aquí.
REVOKE ALL ON FUNCTION public.agent_health_autofix() FROM PUBLIC, anon;

-- cron horario, idempotente
SELECT cron.unschedule('agent-health-selfcheck')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'agent-health-selfcheck');
SELECT cron.schedule('agent-health-selfcheck', '7 * * * *',
                     $$SELECT public.agent_health_selfcheck();$$);
