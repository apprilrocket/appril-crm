-- ════════════════════════════════════════════════════════════════════════════
-- Discovery · Disparo server-side del email de diagnóstico (pg_net trigger)
-- ════════════════════════════════════════════════════════════════════════════
-- Objetivo (Fase 1 "v1-compat"):
--   Al insertar una fila en public.discovery_leads, si trae email, invocar la
--   edge function `send-discovery-email` para enviar el diagnóstico por SES
--   (reutilizando el transporte de inbox-send). El disparo NO depende del
--   navegador.
--
-- Enfoque elegido: pg_net_trigger (HECHOS.recommended_trigger_approach).
--   - message_queue NO tiene drainer/worker de email en la BD → descartada como
--     ruta primaria (obligaría a construir el consumidor).
--   - pg_net no está instalada hoy; se habilita en esta migración. Es la
--     preferencia del usuario.
--
-- Propiedades de seguridad / robustez (verificado contra el proyecto real):
--   - pg_net 0.20.0 disponible: relocatable=false, schema=null → sus objetos
--     viven SIEMPRE en el esquema `net` (no en `extensions`). Por eso NO se usa
--     `with schema extensions` y se invoca `net.http_post(...)`.
--   - net.http_post es ASÍNCRONO: encola en net.http_request_queue (dentro de la
--     transacción) y el background worker entrega FUERA de la transacción. Un
--     fallo de red NO bloquea ni revierte el INSERT del lead.
--   - El trigger es AFTER INSERT: para que NINGÚN error pueda abortar el INSERT
--     del lead (y por tanto submit_discovery_lead), TODO el cuerpo del trigger va
--     envuelto en un guard `exception when others -> raise warning; return NEW`.
--   - Idempotencia de ENCOLADO: columna discovery_leads.email_dispatch_enqueued_at.
--   - URL y secret NO se hardcodean: se leen de current_setting('app.*') con
--     fallback a public.app_config. La ENTREGA real (email_sent_at) la confirma la
--     edge function, fuera de esta migración.
--   - El helper _discovery_cfg() es SECURITY DEFINER y podría filtrar el secret si
--     quedara expuesto vía PostgREST; por eso se le REVOCA EXECUTE a
--     public/anon/authenticated (solo lo usa el trigger, que corre como owner).
--
-- Backward-compatible: no toca submit_discovery_lead ni el scoring.
-- ════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- 0) Extensión pg_net
--    pg_net (relocatable=false, schema=null) crea sus objetos en el esquema `net`.
--    NO se usa `with schema extensions` (rompería la coherencia con net.http_post
--    y/o fallaría). Si el rol de migración no puede crear extensiones, habilitarla
--    desde el Dashboard (Database → Extensions → pg_net) y re-ejecutar; este CREATE
--    es idempotente.
-- ─────────────────────────────────────────────────────────────────────────────
create extension if not exists pg_net;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) Columna de control de idempotencia en discovery_leads
--    Marca cuándo se ENCOLÓ la petición pg_net (no cuándo se entregó el email;
--    la entrega real la confirma la edge function en su propia marca, p.ej.
--    email_sent_at).
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.discovery_leads
  add column if not exists email_dispatch_enqueued_at timestamptz;

comment on column public.discovery_leads.email_dispatch_enqueued_at is
  'Discovery email: momento en que el trigger trg_discovery_lead_email encoló el net.http_post hacia send-discovery-email. NULL = aún no encolado. Idempotencia del disparo (no de la entrega).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) Tabla de configuración (fallback si no se usan los GUC app.*)
--    Permite setear URL/secret sin privilegios de superuser sobre la BD.
--    RLS sin policies + grants revocados: ni anon ni authenticated la leen.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.app_config (
  key         text primary key,
  value       text not null,
  updated_at  timestamptz not null default now()
);

comment on table public.app_config is
  'Config interna key/value para funciones SECURITY DEFINER (p.ej. URL/secret de edge functions). No exponer vía API/PostgREST: RLS sin políticas + grants revocados a public/anon/authenticated.';

alter table public.app_config enable row level security;
-- Sin policies => ningún rol no-superuser puede leer filas. Revoke explícito de
-- los grants por defecto que Supabase concede a anon/authenticated/public.
revoke all on table public.app_config from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) Helper para resolver config con precedencia: current_setting() → app_config
--    SECURITY DEFINER: corre como owner para poder leer app_config bajo RLS.
--    CRÍTICO: se le revoca EXECUTE a public/anon/authenticated para que NADIE
--    pueda extraer el secret invocándola como RPC (solo el trigger, owner, la usa).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._discovery_cfg(p_guc text, p_key text)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v text;
begin
  -- 1) GUC de sesión/DB: current_setting('app.settings.xxx', true) (missing_ok)
  begin
    v := nullif(current_setting(p_guc, true), '');
  exception when others then
    v := null;
  end;

  if v is not null then
    return v;
  end if;

  -- 2) Fallback a tabla app_config
  select nullif(value, '') into v
  from public.app_config
  where key = p_key;

  return v;
end;
$$;

comment on function public._discovery_cfg(text, text) is
  'Resuelve config probando primero current_setting(GUC, true) y luego public.app_config(key). SECURITY DEFINER: EXECUTE revocado a public/anon/authenticated (puede devolver secretos).';

revoke all on function public._discovery_cfg(text, text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) Función trigger: AFTER INSERT ON discovery_leads
--    Todo el cuerpo va dentro de un guard `exception when others` para garantizar
--    que ni un fallo de config, ni de pg_net, ni del UPDATE pueda abortar el
--    INSERT del lead.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.tg_discovery_lead_email()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  v_base_url   text;
  v_secret     text;
  v_url        text;
  v_request_id bigint;
begin
  -- GUARD GLOBAL: este es un AFTER INSERT trigger; cualquier excepción no
  -- controlada revertiría el INSERT del lead (y submit_discovery_lead). Por eso
  -- TODA la lógica va envuelta: ante cualquier fallo, WARNING y se deja pasar.
  begin
    -- Sin email no hay a quién enviar el diagnóstico.
    if NEW.email is null or btrim(NEW.email) = '' then
      return NEW;
    end if;

    -- Idempotencia: si ya se encoló para esta fila, no re-encolar.
    if NEW.email_dispatch_enqueued_at is not null then
      return NEW;
    end if;

    -- Config: base URL de las edge functions y secret de invocación.
    --   app.settings.edge_base_url        -> https://<ref>.supabase.co/functions/v1
    --   app.settings.edge_dispatch_secret -> shared secret dedicado (recomendado)
    v_base_url := public._discovery_cfg('app.settings.edge_base_url', 'edge_base_url');
    v_secret   := public._discovery_cfg('app.settings.edge_dispatch_secret', 'edge_dispatch_secret');

    -- Defensivo: si falta config, avisar y NO abortar el INSERT del lead.
    if v_base_url is null or v_secret is null then
      raise warning '[discovery_email] config ausente (edge_base_url presente=%, secret presente=%); discovery_lead_id=% no encolado; reintentar por barrido/fallback.',
        (v_base_url is not null), (v_secret is not null), NEW.id;
      return NEW;
    end if;

    v_url := rtrim(v_base_url, '/') || '/send-discovery-email';

    -- net.http_post es asíncrono: encola y retorna request_id; la entrega ocurre
    -- fuera de esta transacción, por lo que un fallo de red NO revierte el INSERT.
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object(
                   'Content-Type',  'application/json',
                   'Authorization', 'Bearer ' || v_secret,
                   -- Header propio por si la edge prefiere validar un secret aparte
                   -- del Authorization. La edge puede ignorar el que no use.
                   'x-discovery-dispatch-secret', v_secret
                 ),
      body    := jsonb_build_object(
                   'discovery_lead_id', NEW.id,
                   'source', 'pg_net_trigger'
                 ),
      timeout_milliseconds := 5000
    ) into v_request_id;

    -- Marcar como encolado (idempotencia). AFTER trigger: actualizamos la fila ya
    -- insertada por id (NEW es de solo-lectura aquí). Dispara el trigger
    -- discovery_leads_updated_at (solo bumpea updated_at): inofensivo.
    update public.discovery_leads
       set email_dispatch_enqueued_at = now()
     where id = NEW.id;

  exception when others then
    -- Cualquier fallo (config, net.http_post no disponible, error de red al
    -- encolar, error en el UPDATE) NO debe tumbar el INSERT del lead.
    raise warning '[discovery_email] disparo fallido para discovery_lead_id=% (no aborta el INSERT): %',
      NEW.id, sqlerrm;
  end;

  return NEW;
end;
$$;

comment on function public.tg_discovery_lead_email() is
  'AFTER INSERT en discovery_leads: si hay email y no se encoló antes, dispara net.http_post (async) a la edge send-discovery-email con {discovery_lead_id}. Lee URL/secret de app.settings.* o app_config. Cuerpo envuelto en guard: NUNCA aborta el INSERT.';

-- Hygiene: aunque PostgREST no expone funciones que retornan trigger, revocamos
-- EXECUTE a roles no privilegiados por defensa en profundidad.
revoke all on function public.tg_discovery_lead_email() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) Trigger (idempotente)
-- ─────────────────────────────────────────────────────────────────────────────
drop trigger if exists trg_discovery_lead_email on public.discovery_leads;

create trigger trg_discovery_lead_email
  after insert on public.discovery_leads
  for each row
  execute function public.tg_discovery_lead_email();

-- ════════════════════════════════════════════════════════════════════════════
-- DEPLOY NOTES · cómo setear URL y secret (elige UNA de las dos vías)
-- ════════════════════════════════════════════════════════════════════════════
--
-- _discovery_cfg() resuelve con precedencia:
--   1º current_setting('app.settings.*', true)   2º public.app_config(key)
--
-- Recomendación: usar un SHARED SECRET dedicado (DISCOVERY_DISPATCH_SECRET), NO el
-- service_role key, para acotar el blast radius si el secret se filtra.
--
-- ── Vía A · GUC a nivel de base de datos (requiere rol postgres) ──────────────
--     alter database postgres
--       set app.settings.edge_base_url = 'https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1';
--     alter database postgres
--       set app.settings.edge_dispatch_secret = '<DISCOVERY_DISPATCH_SECRET>';
--   (Surte efecto en NUEVAS conexiones; reiniciar/reconectar el pooler.)
--   NOTA: visible en pg_settings para superusers → si es problema, usar Vía B.
--
-- ── Vía B · tabla app_config (no requiere superuser) ─────────────────────────
--     insert into public.app_config(key, value) values
--       ('edge_base_url', 'https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1'),
--       ('edge_dispatch_secret', '<DISCOVERY_DISPATCH_SECRET>')
--     on conflict (key) do update set value = excluded.value, updated_at = now();
--
-- ── Edge function send-discovery-email (contrato esperado) ───────────────────
--   - POST JSON: { "discovery_lead_id": "<uuid>", "source": "pg_net_trigger" }
--   - Valida el secret recibido (Authorization: Bearer <secret> y/o
--     x-discovery-dispatch-secret) contra su env (DISCOVERY_DISPATCH_SECRET).
--   - Lee discovery_leads por id, arma HTML (tablas + estilos inline; cifras en
--     frontend_calculations.currency.selected_currency / fx_rate_to_usd) y envía
--     vía SES (patrón de supabase/functions/inbox-send/index.ts).
--   - Idempotencia de ENTREGA: marcar su propia columna (p.ej. email_sent_at) y
--     abortar si ya estaba enviado (tolera reintentos de pg_net).
--
-- ── Cómo probar ──────────────────────────────────────────────────────────────
--   1) Config presente:
--        insert into public.discovery_leads (id, email, full_name)
--        values (gen_random_uuid(), 'test@appril.co', 'QA Test');
--        -- verificar encolado:
--        select id, email, email_dispatch_enqueued_at from public.discovery_leads
--          order by created_at desc limit 1;  -- email_dispatch_enqueued_at NOT NULL
--   2) Respuesta/errores de pg_net:
--        select * from net._http_response order by created desc limit 20;
--        select * from net.http_request_queue;            -- cola pendiente
--   3) Config AUSENTE (no debe romper el insert):
--        -- borrar config y repetir el insert: la fila se inserta igual,
--        -- email_dispatch_enqueued_at queda NULL y aparece un WARNING en logs.
--   4) Lead sin email: el insert ocurre y NO se encola (email_dispatch_enqueued_at NULL).
--
-- ── Observabilidad ───────────────────────────────────────────────────────────
--   WARNINGs '[discovery_email] ...' aparecen en los logs de Postgres (get_logs).
--
-- ── Reintentos / barrido (opcional, Fase 2) ──────────────────────────────────
--   Con pg_cron (ya instalado) añadir un job que reencole discovery_leads con
--   email not null y email_dispatch_enqueued_at IS NULL (o sin email_sent_at),
--   llamando net.http_post igual que el trigger. Fuera del alcance de Fase 1.
-- ════════════════════════════════════════════════════════════════════════════
