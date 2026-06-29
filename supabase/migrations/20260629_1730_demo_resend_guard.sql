-- ════════════════════════════════════════════════════════════════════════════
-- Demo viva · reenvío por insistencia (guarda corta) + fin del bloqueo largo
-- ════════════════════════════════════════════════════════════════════════════
-- El cooldown de 24h bloqueaba toda nueva demo, incluso cuando el doctor INSISTÍA
-- ("no me llegó", "mándela otra vez"). Eso no es spam — es solicitud explícita.
--
-- Nuevo modelo en el whatsapp-agent:
--  · demo_cooldown_hours (24): SOLO contexto del prompt — el agente RECUERDA que hubo
--    demo y su resultado, para no re-ofrecerla solo ni re-anunciarla.
--  · demo_resend_guard_minutes (3): la ÚNICA guarda que bloquea crear otra demo, y solo
--    para reintentos/dobles del mismo turno. Pasada la guarda, si el doctor la pide,
--    se crea otra (en otro horario → recordatorio nuevo; ver agente: variación de cupo).
-- ════════════════════════════════════════════════════════════════════════════
insert into public.app_config(key, value) values ('demo_resend_guard_minutes','3')
on conflict (key) do update set value = excluded.value, updated_at = now();
