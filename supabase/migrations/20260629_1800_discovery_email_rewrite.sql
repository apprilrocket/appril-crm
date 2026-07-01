-- ════════════════════════════════════════════════════════════════════════════
-- Rediseño de la biblioteca de emails → funnel Discovery  (copy v2, comercial)
-- ════════════════════════════════════════════════════════════════════════════
-- Objetivo: los 10 templates de email de captación dejan de "vender Appril" y
-- pasan a llevar al profesional al diagnóstico (Discovery), hablando en lenguaje
-- real de consultorio (dinero, tiempo, pacientes, WhatsApp, cancelaciones):
--   email → click → Discovery → resultado → WhatsApp Agent → demo → activación.
--
-- Esta migración NO envía, NO encola, NO activa campañas ni secuencias.
-- Solo:
--   1) Agrega un token opaco `dl_token` por lead (no expone lead_id crudo).
--   2) Extiende crm_launch_campaign para HIDRATAR {{discovery_url}} y
--      {{unsubscribe_url}} en el payload de message_queue (hoy solo hidrata
--      full_name y nombre). Atribución a nivel CAMPAÑA garantizada (UTMs);
--      atribución por LEAD vía `dl` queda PREPARADA (requiere que Discovery
--      resuelva `dl` → lead — P1, fuera de alcance aquí).
--   3) Reescribe subject/text_body/html_body/variables de los 10 templates (v2).
--
-- Revisión requerida ANTES de lanzar cualquier campaña (ver QA doc):
--   P0  List-Unsubscribe header (ya en appril-sender/src/ses.ts; falta deploy).
--   P0  endpoint de baja (supabase/functions/email-unsubscribe; falta deploy).
--   P0  remitente unificado hola@appril.co (Lambda hecho; edge falta deploy).
--   Verificar que el Lambda SES sustituye {{discovery_url}}/{{unsubscribe_url}}
--   igual que {{nombre}}/{{full_name}} (sustitución genérica por clave de payload).
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1) Token opaco por lead (dl) ────────────────────────────────────────────
ALTER TABLE public.leads_master
  ADD COLUMN IF NOT EXISTS dl_token text;

COMMENT ON COLUMN public.leads_master.dl_token IS
  'Token opaco para atribución email→Discovery por lead. NO es el lead_id. Se inyecta como &dl= en discovery_url. La resolución dl→lead en Discovery es P1.';

-- Backfill de los existentes (uuid sin guiones = 32 hex, opaco, único).
UPDATE public.leads_master
  SET dl_token = replace(gen_random_uuid()::text, '-', '')
  WHERE dl_token IS NULL;

-- Default para filas nuevas.
ALTER TABLE public.leads_master
  ALTER COLUMN dl_token SET DEFAULT replace(gen_random_uuid()::text, '-', '');

CREATE UNIQUE INDEX IF NOT EXISTS leads_master_dl_token_key
  ON public.leads_master (dl_token);

-- ── 2) crm_launch_campaign: hidratar discovery_url + unsubscribe_url ─────────
-- IDÉNTICA a 20260626_1300_greeting_name.sql salvo el jsonb_build_object del
-- payload (se agregan 'discovery_url' y 'unsubscribe_url'). No cambia
-- elegibilidad, stats, ni la exigencia de approved_at.
CREATE OR REPLACE FUNCTION public.crm_launch_campaign(p_campaign_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  c              campaigns%ROWTYPE;
  v_template     text;
  v_segments     text[];
  v_list_ids     uuid[];
  v_require_optin boolean;
  v_scheduled    timestamptz;
  v_audience     bigint;
  v_queued       bigint;
  v_disc_base    constant text := 'https://discovery.appril.co/';
  v_unsub_base   constant text := 'https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/email-unsubscribe';
BEGIN
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','campaign_not_found'); END IF;
  IF c.approved_at IS NULL THEN
    RETURN jsonb_build_object('error','not_approved',
      'detail','Falta aprobacion humana (campaigns.approved_at)');
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
    jsonb_build_object(
      'full_name',       lead_var_value(e, 'full_name'),
      'nombre',          lead_var_value(e, 'nombre'),
      -- Atribución: UTM por campaña + template; dl opaco por lead.
      'discovery_url',
        v_disc_base
        || '?utm_source=crm&utm_medium=email'
        || '&utm_campaign=' || c.id::text
        || '&utm_content=' || v_template
        || '&utm_term=A'
        || '&dl=' || coalesce(e.dl_token, ''),
      -- Baja: endpoint HTTPS one-click por lead (identifica por dl, no por lead_id).
      -- Sirve como link visible (GET = confirmación) y como List-Unsubscribe (POST).
      'unsubscribe_url',
        v_unsub_base || '?dl=' || coalesce(e.dl_token, '')
    ),
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
END $fn$;

REVOKE ALL ON FUNCTION public.crm_launch_campaign(uuid) FROM anon, authenticated;

-- ── 3) Reescritura de los 10 templates (copy v2) ────────────────────────────
-- Lenguaje real de consultorio · "usted" · sin claims % · 2ª frase con gancho
-- · CTA único a Discovery · preheader oculto · footer con baja.
-- Marca: botón #F45B69, texto #1f2937, fondo #f8fafc. {{nombre}} ya trae
-- fallback 'Doctor(a)' (lead_var_value).

-- 3.1 cold_intro_email
UPDATE public.message_templates SET
  subject = '¿Sabe cuánto le cuestan los pacientes que no llegan?',
  text_body = $t$Hola {{nombre}},

Un paciente que no llega no es solo una cita perdida.

El consultorio pierde antes: cuando nadie confirma, cuando toca perseguir pacientes por WhatsApp y cuando el espacio queda vacío sin tiempo para recuperarlo.

Por eso creamos un diagnóstico corto para profesionales de salud.

Son 9 preguntas para revisar cuánto dinero, tiempo y oportunidad se pueden estar perdiendo por pacientes que no llegan, cancelaciones tarde y confirmaciones manuales.

No tiene que crear cuenta.

Hacer mi diagnóstico:
{{discovery_url}}

Un saludo,
Mauricio García
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Le ayudamos a encontrar dinero que se le va de las manos.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Un paciente que no llega no es solo una cita perdida.</p><p style="margin:0 0 16px;">El consultorio pierde antes: cuando nadie confirma, cuando toca perseguir pacientes por WhatsApp y cuando el espacio queda vacío sin tiempo para recuperarlo.</p><p style="margin:0 0 16px;">Por eso creamos un diagnóstico corto para profesionales de salud.</p><p style="margin:0 0 16px;">Son 9 preguntas para revisar cuánto dinero, tiempo y oportunidad se pueden estar perdiendo por pacientes que no llegan, cancelaciones tarde y confirmaciones manuales.</p><p style="margin:0 0 16px;">No tiene que crear cuenta.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Hacer mi diagnóstico</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio García<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'cold_intro_email' AND channel = 'email';

-- 3.2 cold_followup_email
UPDATE public.message_templates SET
  subject = '¿Su asistente o usted confirman la agenda de mañana?',
  text_body = $t$Hola {{nombre}},

Le escribo una vez más con una pregunta muy concreta.

Si usted o su asistente tienen que confirmar la agenda de mañana paciente por paciente, ese tiempo también le está costando dinero al consultorio.

Y no solo por las horas que se van en WhatsApp.

También por los pacientes que no responden, las cancelaciones que llegan tarde y los huecos que ya no se alcanzan a llenar.

Preparamos un diagnóstico de 9 preguntas para revisar dónde se puede estar perdiendo tiempo, dinero y oportunidad en su agenda.

Revisar mi agenda:
{{discovery_url}}

Un saludo,
Mauricio
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Ese tiempo también le está costando dinero al consultorio.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Le escribo una vez más con una pregunta muy concreta.</p><p style="margin:0 0 16px;">Si usted o su asistente tienen que confirmar la agenda de mañana paciente por paciente, ese tiempo también le está costando dinero al consultorio.</p><p style="margin:0 0 16px;">Y no solo por las horas que se van en WhatsApp.</p><p style="margin:0 0 16px;">También por los pacientes que no responden, las cancelaciones que llegan tarde y los huecos que ya no se alcanzan a llenar.</p><p style="margin:0 0 16px;">Preparamos un diagnóstico de 9 preguntas para revisar dónde se puede estar perdiendo tiempo, dinero y oportunidad en su agenda.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Revisar mi agenda</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'cold_followup_email' AND channel = 'email';

-- 3.3 hot_intro_email
UPDATE public.message_templates SET
  subject = '¿Cuántas citas le cancelan al mes en su consultorio?',
  text_body = $t$Hola {{nombre}},

Una cancelación no siempre parece grave en el momento.

Lo grave es cuando llega tarde, deja un hueco en la agenda y ya no hay tiempo para recuperar ese espacio.

Eso pasa todos los días en consultorios que dependen de WhatsApp, llamadas o confirmaciones manuales.

Por eso creamos un diagnóstico corto para revisar cuánto le pueden estar costando las citas canceladas, los pacientes que no llegan y el tiempo dedicado a confirmar.

Son 9 preguntas. Sin crear cuenta.

Analizar mi agenda:
{{discovery_url}}

Un saludo,
Mauricio García
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Analice cuánto le cuesta y cómo evitarlo.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Una cancelación no siempre parece grave en el momento.</p><p style="margin:0 0 16px;">Lo grave es cuando llega tarde, deja un hueco en la agenda y ya no hay tiempo para recuperar ese espacio.</p><p style="margin:0 0 16px;">Eso pasa todos los días en consultorios que dependen de WhatsApp, llamadas o confirmaciones manuales.</p><p style="margin:0 0 16px;">Por eso creamos un diagnóstico corto para revisar cuánto le pueden estar costando las citas canceladas, los pacientes que no llegan y el tiempo dedicado a confirmar.</p><p style="margin:0 0 16px;">Son 9 preguntas. Sin crear cuenta.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Analizar mi agenda</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio García<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'hot_intro_email' AND channel = 'email';

-- 3.4 hot_followup_email
UPDATE public.message_templates SET
  subject = '¿Para usted es un problema que los pacientes cancelen o no lleguen?',
  text_body = $t$Hola {{nombre}},

Si los pacientes que cancelan o no llegan no son un problema en su consultorio, este correo no es prioridad.

Pero si esas citas sí le dejan huecos, tiempo perdido o ingresos que no se recuperan, vale la pena medirlo.

Creamos un diagnóstico corto para revisar dónde se pierden citas antes de que el paciente llegue.

También le muestra qué parte pesa más: pacientes que no confirman, cancelaciones tarde, WhatsApp manual o espacios que no se alcanzan a llenar.

Hacer el diagnóstico:
{{discovery_url}}

Un saludo,
Mauricio
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Le ayudamos a entender dónde se pierden y cómo evitarlo.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Si los pacientes que cancelan o no llegan no son un problema en su consultorio, este correo no es prioridad.</p><p style="margin:0 0 16px;">Pero si esas citas sí le dejan huecos, tiempo perdido o ingresos que no se recuperan, vale la pena medirlo.</p><p style="margin:0 0 16px;">Creamos un diagnóstico corto para revisar dónde se pierden citas antes de que el paciente llegue.</p><p style="margin:0 0 16px;">También le muestra qué parte pesa más: pacientes que no confirman, cancelaciones tarde, WhatsApp manual o espacios que no se alcanzan a llenar.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Hacer el diagnóstico</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'hot_followup_email' AND channel = 'email';

-- 3.5 super_hot_email
UPDATE public.message_templates SET
  subject = 'Sus pacientes necesitan ver innovación',
  text_body = $t$Hola {{nombre}},

Le escribo por email para no insistirle más por WhatsApp.

Sus pacientes ya viven todo desde el celular; confirmar, cancelar o reagendar una cita también debería ser fácil para ellos.

Appril ayuda a que su consultorio se vea más ordenado, más moderno y menos dependiente de estar persiguiendo pacientes por mensajes.

Puede empezar con un diagnóstico corto para revisar dónde está perdiendo citas, tiempo o espacios.

Y si quiere avanzar, puede activar un mes gratis sin tarjeta.

Hacer mi diagnóstico:
{{discovery_url}}

Un saludo,
Mauricio García
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Active un mes gratis con Appril y mejore la atención a sus pacientes.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Le escribo por email para no insistirle más por WhatsApp.</p><p style="margin:0 0 16px;">Sus pacientes ya viven todo desde el celular; confirmar, cancelar o reagendar una cita también debería ser fácil para ellos.</p><p style="margin:0 0 16px;">Appril ayuda a que su consultorio se vea más ordenado, más moderno y menos dependiente de estar persiguiendo pacientes por mensajes.</p><p style="margin:0 0 16px;">Puede empezar con un diagnóstico corto para revisar dónde está perdiendo citas, tiempo o espacios.</p><p style="margin:0 0 16px;">Y si quiere avanzar, puede activar un mes gratis sin tarjeta.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Hacer mi diagnóstico</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio García<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'super_hot_email' AND channel = 'email';

-- 3.6 warm_reactivation_1
UPDATE public.message_templates SET
  subject = '¿Todavía confirma pacientes por WhatsApp?',
  text_body = $t$Hola {{nombre}},

Una pregunta rápida:

¿Todavía confirma pacientes por WhatsApp, uno por uno?

Ese trabajo parece normal hasta que se suma en horas, interrupciones y citas que quedan en el aire porque el paciente no responde.

También le quita tiempo a usted o a su asistente, y puede dejar huecos que nadie alcanza a llenar.

Hicimos un diagnóstico corto para revisar cuánto tiempo, dinero y oportunidad se pueden estar perdiendo en esa parte de la agenda.

Son 9 preguntas. Sin crear cuenta.

Revisar mi agenda:
{{discovery_url}}

Un saludo,
Mauricio
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Revise cuánto tiempo pierde persiguiendo a sus pacientes para que confirmen.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Una pregunta rápida:</p><p style="margin:0 0 16px;">¿Todavía confirma pacientes por WhatsApp, uno por uno?</p><p style="margin:0 0 16px;">Ese trabajo parece normal hasta que se suma en horas, interrupciones y citas que quedan en el aire porque el paciente no responde.</p><p style="margin:0 0 16px;">También le quita tiempo a usted o a su asistente, y puede dejar huecos que nadie alcanza a llenar.</p><p style="margin:0 0 16px;">Hicimos un diagnóstico corto para revisar cuánto tiempo, dinero y oportunidad se pueden estar perdiendo en esa parte de la agenda.</p><p style="margin:0 0 16px;">Son 9 preguntas. Sin crear cuenta.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Revisar mi agenda</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'warm_reactivation_1' AND channel = 'email';

-- 3.7 warm_reactivation_2
UPDATE public.message_templates SET
  subject = 'Las citas que se pierden le cuestan mucha plata',
  text_body = $t$Hola {{nombre}},

Las citas que se pierden no siempre se ven como plata perdida el mismo día.

A veces se ven como una asistente escribiendo por WhatsApp, un paciente que no responde, una cancelación tarde o un hueco que quedó vacío.

Pero al final del mes, todo suma.

Por eso preparamos un diagnóstico corto para revisar cuánto dinero, tiempo y oportunidad se pueden estar escapando en su agenda.

No tiene que crear cuenta.

Realizar el diagnóstico:
{{discovery_url}}

Un saludo,
Mauricio
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Dinero, tiempo y oportunidad. Realice este diagnóstico y vea cómo recuperarlos.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Las citas que se pierden no siempre se ven como plata perdida el mismo día.</p><p style="margin:0 0 16px;">A veces se ven como una asistente escribiendo por WhatsApp, un paciente que no responde, una cancelación tarde o un hueco que quedó vacío.</p><p style="margin:0 0 16px;">Pero al final del mes, todo suma.</p><p style="margin:0 0 16px;">Por eso preparamos un diagnóstico corto para revisar cuánto dinero, tiempo y oportunidad se pueden estar escapando en su agenda.</p><p style="margin:0 0 16px;">No tiene que crear cuenta.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Realizar el diagnóstico</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'warm_reactivation_2' AND channel = 'email';

-- 3.8 demo_email_intro  (corrige bug de \n literal en text_body)
UPDATE public.message_templates SET
  subject = 'Su consultorio está perdiendo plata y usted lo sabe',
  text_body = $t$Hola {{nombre}},

Puede que su consultorio esté perdiendo plata sin que aparezca como una factura.

A veces se pierde en pacientes que no llegan, cancelaciones tarde, confirmaciones por WhatsApp y espacios que no se alcanzan a llenar.

Antes de hablar de Appril, le propongo medirlo.

Creamos un diagnóstico de 9 preguntas para revisar cuánto dinero, tiempo y oportunidad se pueden estar escapando en su agenda.

Al final verá si tiene sentido avanzar y cómo podría recuperarlo.

Hacer el diagnóstico:
{{discovery_url}}

Un saludo,
Mauricio
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">9 preguntas para saber cuánto, dónde y cómo recuperarla.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Puede que su consultorio esté perdiendo plata sin que aparezca como una factura.</p><p style="margin:0 0 16px;">A veces se pierde en pacientes que no llegan, cancelaciones tarde, confirmaciones por WhatsApp y espacios que no se alcanzan a llenar.</p><p style="margin:0 0 16px;">Antes de hablar de Appril, le propongo medirlo.</p><p style="margin:0 0 16px;">Creamos un diagnóstico de 9 preguntas para revisar cuánto dinero, tiempo y oportunidad se pueden estar escapando en su agenda.</p><p style="margin:0 0 16px;">Al final verá si tiene sentido avanzar y cómo podría recuperarlo.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Hacer el diagnóstico</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'demo_email_intro' AND channel = 'email';

-- 3.9 demo_email_followup
UPDATE public.message_templates SET
  subject = '¿Sabe si está administrando bien su consultorio?',
  text_body = $t$Hola {{nombre}},

La mayoría de consultorios cree que el problema es tener más pacientes.

Pero muchas veces el dinero se está yendo en otra parte: citas que se cancelan tarde, pacientes que no llegan y horas dedicadas a confirmar la agenda.

Por eso le dejo una forma simple de revisarlo.

El diagnóstico toma 9 preguntas y le muestra dónde se pueden estar perdiendo dinero, tiempo y oportunidades dentro de su agenda.

Revisar mi consultorio:
{{discovery_url}}

Un saludo,
Mauricio
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Realice este diagnóstico y vea cuánto dinero está dejando sobre la mesa.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">La mayoría de consultorios cree que el problema es tener más pacientes.</p><p style="margin:0 0 16px;">Pero muchas veces el dinero se está yendo en otra parte: citas que se cancelan tarde, pacientes que no llegan y horas dedicadas a confirmar la agenda.</p><p style="margin:0 0 16px;">Por eso le dejo una forma simple de revisarlo.</p><p style="margin:0 0 16px;">El diagnóstico toma 9 preguntas y le muestra dónde se pueden estar perdiendo dinero, tiempo y oportunidades dentro de su agenda.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Revisar mi consultorio</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'demo_email_followup' AND channel = 'email';

-- 3.10 hot_discovery_email_v1_1782510240077
UPDATE public.message_templates SET
  subject = '¿Sabe cuánto tiempo le toma perseguir pacientes?',
  text_body = $t$Hola {{nombre}},

Una pregunta concreta:

¿Sabe cuánto tiempo le toma a usted o a su equipo perseguir pacientes para que confirmen una cita?

Ese tiempo casi nunca se mide, pero sí cuesta: mensajes, llamadas, interrupciones, pacientes que no responden y citas que pueden terminar vacías.

Por eso preparamos un diagnóstico corto para revisar cuánto dinero, tiempo y oportunidad se pueden estar perdiendo antes de que el paciente llegue.

Son 9 preguntas. Sin crear cuenta.

Hacer mi diagnóstico:
{{discovery_url}}

Un saludo,
Mauricio
Appril$t$,
  html_body = $h$<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Appril</title></head><body style="margin:0;padding:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif;color:#1f2937;"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">Ese tiempo representa mucha plata para su consultorio. Haga este diagnóstico.</div><table width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;padding:32px 16px;"><tr><td align="center"><table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;"><tr><td style="padding:24px 28px;border-bottom:1px solid #f1f5f9;"><span style="font-size:22px;font-weight:700;color:#F45B69;">Appril</span></td></tr><tr><td style="padding:28px;font-size:15px;line-height:1.65;color:#1f2937;"><p style="margin:0 0 16px;">Hola {{nombre}},</p><p style="margin:0 0 16px;">Una pregunta concreta:</p><p style="margin:0 0 16px;">¿Sabe cuánto tiempo le toma a usted o a su equipo perseguir pacientes para que confirmen una cita?</p><p style="margin:0 0 16px;">Ese tiempo casi nunca se mide, pero sí cuesta: mensajes, llamadas, interrupciones, pacientes que no responden y citas que pueden terminar vacías.</p><p style="margin:0 0 16px;">Por eso preparamos un diagnóstico corto para revisar cuánto dinero, tiempo y oportunidad se pueden estar perdiendo antes de que el paciente llegue.</p><p style="margin:0 0 16px;">Son 9 preguntas. Sin crear cuenta.</p><p style="margin:24px 0 0;"><a href="{{discovery_url}}" style="background:#F45B69;color:#ffffff;padding:13px 22px;border-radius:8px;text-decoration:none;font-weight:700;display:inline-block;">Hacer mi diagnóstico</a></p><p style="margin:28px 0 0;color:#4b5563;font-size:14px;">Un saludo,<br>Mauricio<br>Appril</p></td></tr><tr><td style="padding:18px 28px;background:#f9fafb;border-top:1px solid #e5e7eb;"><p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">Appril · appril.co<br>Recibió este correo porque su contacto está en nuestra base de profesionales de salud. <a href="{{unsubscribe_url}}" style="color:#9ca3af;text-decoration:underline;">Cancelar suscripción</a></p></td></tr></table></td></tr></table></body></html>$h$,
  variables = '["nombre","discovery_url","unsubscribe_url"]'::jsonb,
  updated_at = now()
WHERE template_key = 'hot_discovery_email_v1_1782510240077' AND channel = 'email';

COMMIT;

-- ── Verificación (manual, no destructiva) ───────────────────────────────────
-- select template_key, subject, variables, updated_at
--   from public.message_templates where channel='email' order by template_key;
-- select count(*) from public.leads_master where dl_token is null;  -- esperado: 0
