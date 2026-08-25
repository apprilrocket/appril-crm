-- ============================================================================
-- El canario deja de escalar por UN solo sondeo fallido
-- ============================================================================
--
-- SÍNTOMA (24-25 ago 2026): 14 incidentes `canary_down` en 48 horas, en AMBOS
-- agentes, todos escalados por WhatsApp al dueño.
--
-- EVIDENCIA DE QUE ERA RUIDO, NO DEGRADACIÓN:
--   · 206 corridas reales del agente en 9 días con CERO errores.
--   · En 48h los profesionales enviaron 56 mensajes y recibieron 153 respuestas;
--     pacientes 65/65. Nada quedó sin responder.
--   · Tasa de fallo del sondeo ≈1,5% (3-4 de cada 250 llamadas), repartida entre
--     503 transitorios de Anthropic y timeouts sueltos del canario.
--
-- CAUSA: `agent_health_canary_collect()` abría incidente al PRIMER sondeo
-- fallido. Anthropic, como cualquier API, tiene 429/529 ocasionales. Un canal de
-- alertas que suena por cada tropiezo se vuelve ruido de fondo — y esa es
-- exactamente la dinámica que en julio hizo que 37 avisos REALES se ignoraran.
--
-- QUÉ CAMBIA: se exigen DOS sondeos fallidos consecutivos para escalar.
-- QUÉ NO CAMBIA (deliberado): NADA se oculta. La tabla nueva
-- `agent_health_canary_log` registra TODOS los sondeos, fallen o no — hoy no se
-- guardaba ninguno. La visibilidad forense aumenta; lo que baja es el ruido.
--
-- Costo: detectar una caída real tarda ~10 min más (2 ticks en vez de 1). La
-- caída del 12-jul duró horas y la del watchdog 32 días: 10 minutos es
-- irrelevante frente al riesgo de que el dueño deje de mirar el canal.
--
-- ---------------------------------------------------------------------------
-- REVISIÓN ADVERSARIAL (appril-data-expert, 25-ago). Correcciones incorporadas:
--   B1 (BLOQUEANTE) Un timeout de pg_net deja `status_code` NULL → la expresión
--      `ok` daba NULL → 23502 en columna NOT NULL → excepción → `agent_health_
--      tick` aborta ENTERO (collect corre sin EXCEPTION a propósito) → el DELETE
--      de limpieza no corre → el siguiente tick revienta igual. Es el MISMO
--      bucle cerrado del 17-jul que esta serie de migraciones vino a reparar.
--      Verificado contra prod: había 2 filas reales con status_code NULL que lo
--      habrían disparado en el siguiente tick. Cerrado con coalesce(...,false).
--   B2 (BLOQUEANTE) `content::jsonb` lanza 22P02 con body vacío o truncado y
--      content_type json. El guard `LIKE` NO protege: el orden de evaluación de
--      un AND no está garantizado. Cerrado con un helper que no puede lanzar.
--   A1 (ALTO) Un sondeo atascado se registraba a los 21 min Y otra vez a los 31
--      (el DELETE usaba 25 min y corría DESPUÉS) → dos filas fallidas de UN solo
--      sondeo → escalaba con un único fallo, justo lo que se quiere evitar.
--      Cerrado consumiendo cada request UNA vez con DELETE ... RETURNING.
--   M1 Owner alineado con `agent_health_canary_requests` (postgres, verificado):
--      con RLS sin políticas, si el owner no es el definer, el INSERT falla y
--      tumba el tick.
--   M2 Faltaba REVOKE en la secuencia del bigserial (en Supabase las secuencias
--      nuevas de `public` nacen con anon=rwU por default privileges).
--
-- CAMBIO DE COMPORTAMIENTO DOCUMENTADO: los timeouts usaban una clave de dedupe
-- separada (`source:timeout:hora`); ahora comparten `source:hora` con los down,
-- así que un timeout y un down de la misma hora producen UN incidente en vez de
-- dos. Es deseable (menos ruido) pero es un cambio, y queda escrito.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.agent_health_canary_log (
  id          bigserial PRIMARY KEY,
  source      text        NOT NULL,
  checked_at  timestamptz NOT NULL DEFAULT now(),
  ok          boolean     NOT NULL,
  status_code int,
  detail      text
);

CREATE INDEX IF NOT EXISTS ix_canary_log_source_id
  ON public.agent_health_canary_log (source, id DESC);

-- Patrón platform_flags: RLS activa SIN políticas + REVOKE.
ALTER TABLE public.agent_health_canary_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE    public.agent_health_canary_log        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.agent_health_canary_log_id_seq FROM PUBLIC, anon, authenticated;

-- M1: el owner de la tabla salta RLS; ningún otro rol lo hace.
DO $do$
DECLARE v_owner name;
BEGIN
  SELECT tableowner INTO v_owner FROM pg_tables
   WHERE schemaname = 'public' AND tablename = 'agent_health_canary_requests';
  IF v_owner IS NOT NULL
     AND v_owner <> (SELECT tableowner FROM pg_tables
                      WHERE schemaname='public' AND tablename='agent_health_canary_log') THEN
    EXECUTE format('ALTER TABLE    public.agent_health_canary_log        OWNER TO %I', v_owner);
    EXECUTE format('ALTER SEQUENCE public.agent_health_canary_log_id_seq OWNER TO %I', v_owner);
  END IF;
END $do$;

-- B2: única forma de mirar el body sin poder lanzar excepción. Un 200 con body
-- ilegible se considera sano: el 200 prueba que la función corrió, y preferimos
-- no inventar ruido. Una caída real llega como no-200 o como ok:false legible.
CREATE OR REPLACE FUNCTION public.agent_health_json_says_not_ok(p_content text)
 RETURNS boolean LANGUAGE plpgsql IMMUTABLE
AS $function$
BEGIN
  RETURN coalesce((p_content::jsonb ->> 'ok') = 'false', false);
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END $function$;

REVOKE ALL ON FUNCTION public.agent_health_json_says_not_ok(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.agent_health_canary_collect()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- 1) Consumir cada sondeo EXACTAMENTE UNA VEZ y registrarlo (ok y fallidos).
  --    El DELETE ... RETURNING hace que registrar y limpiar sean el mismo
  --    statement: ningún sondeo puede contarse dos veces [A1]. Los que aún no
  --    tienen respuesta y llevan <20 min esperan al próximo tick.
  --    coalesce(...,false) [B1]: sin respuesta o status NULL = sondeo fallido.
  --    ORDER BY fired_at: los `id` quedan en orden cronológico real, así
  --    `id DESC` significa de verdad "los más recientes".
  WITH consumidos AS (
    DELETE FROM agent_health_canary_requests cr
    WHERE EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = cr.request_id)
       OR cr.fired_at < now() - interval '20 minutes'
    RETURNING cr.request_id, cr.source, cr.fired_at
  )
  INSERT INTO agent_health_canary_log (source, ok, status_code, detail)
  SELECT c.source,
         coalesce(
           r.id IS NOT NULL
           AND r.status_code = 200
           AND NOT (r.content_type LIKE 'application/json%'
                    AND agent_health_json_says_not_ok(r.content)),
           false),
         r.status_code,
         left(coalesce(r.content, r.error_msg, 'sin respuesta de pg_net en 20 min'), 500)
  FROM consumidos c
  LEFT JOIN net._http_response r ON r.id = c.request_id
  ORDER BY c.fired_at, c.request_id;

  -- 2) Escalar SOLO si los DOS últimos sondeos de esa fuente fallaron.
  --    El JOIN contra rn=2 garantiza que existan dos sondeos: con uno solo
  --    (fuente nueva, o log recién creado) no hay fila y no se escala.
  WITH recientes AS (
    SELECT l.source, l.ok, l.status_code, l.detail,
           row_number() OVER (PARTITION BY l.source ORDER BY l.id DESC) AS rn
    FROM agent_health_canary_log l
  )
  INSERT INTO agent_health_incidents (source, incident_type, ref_id, details)
  SELECT u.source,
         CASE WHEN u.status_code = 200 THEN 'canary_degraded' ELSE 'canary_down' END,
         u.source || ':' || to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24:00'),
         jsonb_build_object('status_code', u.status_code, 'body', u.detail,
                            'nota', 'dos sondeos consecutivos fallidos')
  FROM recientes u
  JOIN recientes p ON p.source = u.source AND p.rn = 2
  WHERE u.rn = 1 AND NOT u.ok AND NOT p.ok
  ON CONFLICT (source, incident_type, coalesce(ref_id, ''))
    WHERE status IN ('open','notified') DO NOTHING;

  -- 3) Retención del log (7 días ≈ 1.000 sondeos por fuente; la comparación
  --    solo mira los 2 últimos, así que nunca borra lo que necesita).
  DELETE FROM agent_health_canary_log WHERE checked_at < now() - interval '7 days';
END $function$;

REVOKE ALL ON FUNCTION public.agent_health_canary_collect() FROM PUBLIC, anon, authenticated;
