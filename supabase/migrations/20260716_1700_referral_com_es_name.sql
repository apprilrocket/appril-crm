-- Referidos — el template quedó aprobado en la WABA de VENTAS con el nombre
-- `referral_com_es` (no `referral_es`, que se había creado por error en la WABA
-- del asistente del doctor). Se ajusta el wa_template_name a lo que existe en la
-- cuenta comercial que usa queue-sender. Estructura idéntica (header={{referido_
-- nombre}}, body={{referidor_nombre}}) → wa_components sin cambios.
UPDATE public.message_templates
SET wa_template_name = 'referral_com_es', updated_at = now()
WHERE template_key = 'referido_invitacion';
