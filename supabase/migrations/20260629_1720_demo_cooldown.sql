-- ════════════════════════════════════════════════════════════════════════════
-- Demo viva · cooldown configurable (no bloqueo permanente)
-- ════════════════════════════════════════════════════════════════════════════
-- El whatsapp-agent dejaba de ofrecer/crear demo si EL LEAD había tenido UNA demo
-- alguna vez (demoAlreadyCreated all-time) → un doctor que vuelve y la pide de nuevo
-- (solicitud explícita, NO spam) se quedaba sin demo.
--
-- Fix (lado CRM): el agente ahora acota demo_created/demo_callback_sent a una ventana
-- de cooldown. Fuera de la ventana, una petición explícita crea una demo fresca.
-- 24h se alinea con el dedup de prod (assistant_create_appointment dedup exacto-por-cupo)
-- porque la demo agenda "mañana": al día siguiente el starts_at_utc es otro y prod NO
-- deduplica. appril-web NO requiere cambios.
--
-- Aditivo (solo config). El default en código también es 24 si la fila no existe.
-- ════════════════════════════════════════════════════════════════════════════
insert into public.app_config(key, value) values ('demo_cooldown_hours','24')
on conflict (key) do update set value = excluded.value, updated_at = now();
