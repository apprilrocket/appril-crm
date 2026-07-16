-- ═══════════════════════════════════════════════════════════════════════════
-- Referidos — cablear el template nuevo referral_es (16-jul-2026)
--
-- El trigger enqueue_referral_invite (AFTER INSERT ON leads_master para
-- source='appril_referral') encola template_key='referido_invitacion' con
-- payload {referido_nombre, referidor_nombre}. Se reapunta esa fila al template
-- de Meta nuevo `referral_es` (creado por el dueño): variable en el HEADER
-- (nombre del referido) + variable en el BODY (nombre del referidor), con dos
-- botones quick-reply ("Si. Atiendo pacientes/clientes" / "Quiero más
-- información"). queue-sender usa wa_components (injectPayload reemplaza los
-- {{var}} por el payload); por eso se declaran header y body explícitos — si
-- fuera null, buildSimpleBody metería todo al body y no cuadraría con la
-- estructura header+body del template. Los botones quick-reply son estáticos
-- (definidos en la plantilla): NO van en los componentes del envío.
-- ═══════════════════════════════════════════════════════════════════════════

UPDATE public.message_templates
SET
  wa_template_name = 'referral_es',
  wa_language      = 'es',
  wa_components    = jsonb_build_array(
    jsonb_build_object('type', 'header', 'parameters',
      jsonb_build_array(jsonb_build_object('type', 'text', 'text', '{{referido_nombre}}'))),
    jsonb_build_object('type', 'body', 'parameters',
      jsonb_build_array(jsonb_build_object('type', 'text', 'text', '{{referidor_nombre}}')))
  ),
  variables   = '["referido_nombre","referidor_nombre"]'::jsonb,
  description = 'Apertura comercial a un referido por un paciente (template Meta referral_es). Header={{referido_nombre}}, Body={{referidor_nombre}}, 2 botones quick-reply (ambos = interés).',
  status      = 'active',
  updated_at  = now()
WHERE template_key = 'referido_invitacion';
