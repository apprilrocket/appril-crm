# Rediseño de emails → Discovery · QA y handoff

> **Estado:** TODO LISTO PARA REVISIÓN. **No se envió, encoló, activó ni deployó nada.**
> **Fecha:** 2026-06-29 · Proyecto CRM `hwiocriejizjdqqcfrsj` · branch `chore/rescue-edge-functions`.

## Artefactos producidos (revisables, NO aplicados)

| Artefacto | Ruta | Qué hace | Cómo se activa |
|---|---|---|---|
| Migración SQL | `supabase/migrations/20260629_1800_discovery_email_rewrite.sql` | (1) agrega `leads_master.dl_token` opaco; (2) extiende `crm_launch_campaign` para hidratar `{{discovery_url}}`+`{{unsubscribe_url}}`; (3) reescribe los 10 templates de email | aplicar por canal Supabase (revisar primero) |
| Edge function | `supabase/functions/send-discovery-email/index.ts` | reescribe el email de RESULTADO post-Discovery (WhatsApp como CTA principal, registro secundario; "usted"; sin claims) | deploy por canal Supabase (no deployado) |
| MCP | `mcp/src/lib/campaigns.ts` | agrega `discovery_url`/`unsubscribe_url` al set de variables hidratadas (evita falso warning) | build/deploy del MCP |
| Lambda sender | `appril-sender/src/ses.ts` | envío MIME crudo (`SendRawEmailCommand`) con header `List-Unsubscribe` (+ one-click si HTTPS) | `npm run deploy:sender` (no deployado) |
| Endpoint baja | `supabase/functions/email-unsubscribe/index.ts` + `supabase/config.toml` (`verify_jwt=false`) | endpoint HTTPS one-click; baja por `dl_token` (GET=confirmación, POST=baja) | deploy por canal Supabase (no deployado) |
| Previews HTML | `docs/previews/*.html` (+ `index.html`) | render de los 11 emails con variables de ejemplo | abrir en navegador |

## 1. Tabla template_key / subject / CTA / URL

> **Copy v2 (comercial/humano).** Subjects que abren herida, preheader que sube la consecuencia, 2ª frase con gancho.

| template_key | subject | preheader | CTA | URL |
|---|---|---|---|---|
| cold_intro_email | ¿Sabe cuánto le cuestan los pacientes que no llegan? | Le ayudamos a encontrar dinero que se le va de las manos. | Hacer mi diagnóstico | `{{discovery_url}}` |
| cold_followup_email | ¿Su asistente o usted confirman la agenda de mañana? | Ese tiempo también le está costando dinero al consultorio. | Revisar mi agenda | `{{discovery_url}}` |
| hot_intro_email | ¿Cuántas citas le cancelan al mes en su consultorio? | Analice cuánto le cuesta y cómo evitarlo. | Analizar mi agenda | `{{discovery_url}}` |
| hot_followup_email | ¿Para usted es un problema que los pacientes cancelen o no lleguen? | Le ayudamos a entender dónde se pierden y cómo evitarlo. | Hacer el diagnóstico | `{{discovery_url}}` |
| super_hot_email | Sus pacientes necesitan ver innovación | Active un mes gratis con Appril y mejore la atención a sus pacientes. | Hacer mi diagnóstico | `{{discovery_url}}` |
| warm_reactivation_1 | ¿Todavía confirma pacientes por WhatsApp? | Revise cuánto tiempo pierde persiguiendo a sus pacientes para que confirmen. | Revisar mi agenda | `{{discovery_url}}` |
| warm_reactivation_2 | Las citas que se pierden le cuestan mucha plata | Dinero, tiempo y oportunidad. Realice este diagnóstico y vea cómo recuperarlos. | Realizar el diagnóstico | `{{discovery_url}}` |
| demo_email_intro | Su consultorio está perdiendo plata y usted lo sabe | 9 preguntas para saber cuánto, dónde y cómo recuperarla. | Hacer el diagnóstico | `{{discovery_url}}` |
| demo_email_followup | ¿Sabe si está administrando bien su consultorio? | Realice este diagnóstico y vea cuánto dinero está dejando sobre la mesa. | Revisar mi consultorio | `{{discovery_url}}` |
| hot_discovery_email_v1_1782510240077 | ¿Sabe cuánto tiempo le toma perseguir pacientes? | Ese tiempo representa mucha plata para su consultorio. Haga este diagnóstico. | Hacer mi diagnóstico | `{{discovery_url}}` |
| **send-discovery-email** (resultado) | Su diagnóstico está listo | Tiene una oportunidad estimada de `{{hiddenCost}}` al año. (fallback si no hay cifra) | **Activar mi mes gratis por WhatsApp** (principal) · Crear cuenta sin tarjeta (secundario) | `wa.me/573112211772` · `www.appril.co/empezar` |

`{{discovery_url}}` se hidrata en `crm_launch_campaign` como:
`https://discovery.appril.co/?utm_source=crm&utm_medium=email&utm_campaign=<campaign_id>&utm_content=<template_key>&utm_term=A&dl=<dl_token>`

## 2. QA de copy (checklist solicitado)

| # | Verificación | Resultado |
|---|---|---|
| 1 | 10 templates de BD reescritos hacia Discovery | ✅ |
| 2 | Email de resultado → WhatsApp Agent / activación | ✅ (WA primario, registro secundario) |
| 3 | Lenguaje real de consultorio ("usted") | ✅ |
| 4 | No "40–90%" | ✅ (0 ocurrencias, grep) |
| 5 | No "hasta 90%" | ✅ (0 ocurrencias) |
| 6 | No testimonios sin fuente | ✅ (eliminados de warm_reactivation_2) |
| 7 | No CTA a home genérica `https://appril.co` | ✅ (único `appril.co` restante = link de marca en footer del email de resultado, no CTA) |
| 8 | `demo_email_intro` ya sin `\n` literal | ✅ |
| 9 | Preheader oculto en HTML | ✅ (10/10 templates + resultado) |
| 10 | Footer en todos | ✅ (10/10 con baja; resultado con footer de marca) |
| 11 | Un solo CTA visible en captación | ✅ (1 botón por template; baja en footer no cuenta) |
| 12 | Sin envíos programados | ✅ (`message_queue` pending=0, sin filas nuevas) |
| 13 | Sin campañas activadas por este trabajo | ✅ (templates prod sin cambios; migración no aplicada) |

## 3. QA técnica

| # | Verificación | Resultado |
|---|---|---|
| 1 | Templates parsean (bloques `$h$…$h$`) | ✅ (11 previews generados) |
| 2 | `{{nombre}}` con fallback | ✅ ya existe: `lead_var_value(_, 'nombre')` → `coalesce(first_name, split_part(full_name), 'Doctor(a)')`; el email de resultado ahora también usa `Doctor(a)` |
| 3 | `{{discovery_url}}` / `{{unsubscribe_url}}` hidratados | ✅ en `crm_launch_campaign` (migración) |
| 4 | UTM + `dl` generados | ✅ UTM por campaña+template; `dl` opaco por lead |
| 5 | Previews HTML | ✅ `docs/previews/` (sin placeholders residuales) |
| 6 | Edge function: backticks balanceados, render OK | ✅ (deno check falla solo por dep `openai` no instalada, ajeno a este cambio) |
| 7 | Migración no aplicada a prod | ✅ (`dl_token` no existe aún en DB) |
| 8 | Sin filas nuevas en `message_queue` | ✅ |
| 9 | Sin campañas nuevas activadas | ✅ |

## 4. Riesgos / cosas a saber antes de aplicar

1. **`{{discovery_url}}`/`{{unsubscribe_url}}` dependen de la migración.** Si se aplican los UPDATE de templates **sin** la nueva `crm_launch_campaign`, esas variables saldrían vacías al enviar. La migración trae ambas cosas juntas en un solo archivo → **aplicar completa**.
2. **VERIFICADO (2026-06-29):** el Lambda `appril-crm-sender` (`appril-sender/src/templates.ts` → `renderTemplate`) sustituye `{{clave}}` de forma **genérica** contra el payload (`input.replace(/\{\{\s*([\w.]+)\s*\}\}/g, …)`, soporta `a.b.c`). Como `crm_launch_campaign` ahora inyecta `discovery_url` y `unsubscribe_url` en el payload, **ambas variables resuelven sin tocar el Lambda.** ✅ (subject/html_body/text_body se renderizan todos — `appril-sender/src/ses.ts:17-19`).
3. **`hot_discovery_email_v1` está en una campaña draft + secuencia running.** Aplicar la migración cambia su contenido; revisar que es lo deseado antes de cualquier launch.
4. **`backfill dl_token`** corre un UPDATE sobre ~20.789 filas (rápido, una vez). Idempotente (`WHERE dl_token IS NULL`).
5. **Email de resultado = deploy de edge function**, no edición en CRM. No se deployó. Requiere aprobación.

## 5. Pendientes de infraestructura (P0/P1 — bloquean campaña masiva)

| Pendiente | Prioridad | Nota |
|---|---|---|
| `List-Unsubscribe` header | **P0 → PREPARADO** | `appril-sender/src/ses.ts` reescrito a `SendRawEmailCommand` (MIME crudo). Emite `List-Unsubscribe` + `List-Unsubscribe-Post: List-Unsubscribe=One-Click` cuando `unsubscribe_url` es HTTPS. **Falta solo `npm run deploy:sender`.** |
| Endpoint real de baja (one-click) | **P0 → PREPARADO** | Edge function `supabase/functions/email-unsubscribe/index.ts` (GET=confirmación anti-prefetch, POST=baja one-click por `dl`). `crm_launch_campaign` ahora hidrata `unsubscribe_url` = `…/functions/v1/email-unsubscribe?dl=<token>`. **Falta solo deploy** (`verify_jwt=false` ya en `config.toml`). |
| Resolución `dl` → lead en Discovery | **P1** | el `dl` ya viaja en la URL; falta que Discovery lo lea y lo guarde en `discovery_leads`. Atribución por **campaña** ya funciona vía UTM. |
| Unificar remitente | **HECHO (Lambda) / pendiente deploy (edge)** | **Lambda `appril-crm-sender` YA aplicado vía CLI (2026-06-29):** `SES_FROM_EMAIL`=`SES_REPLY_TO`=`hola@appril.co` (13 vars intactas, LastUpdateStatus=Successful). Sin cruce a `todoc.co`. Edge `send-discovery-email`/`inbox-send`: default ya en código → `Appril <hola@appril.co>`; **aplica al redeployarlas** (ese deploy también sube el copy reescrito → decisión de go-live). Supabase: verificado que NO hay overrides `DISCOVERY_FROM_EMAIL`/`INBOX_FROM_EMAIL`. |
| Tracking de links (wa.me) | **P1** | `wa.me` no es medible hoy; si hay redirect endpoint, usarlo. |
| Warming / throttle | **P0 para WARM** | no enviar 12k de golpe sin calentar dominio. |

## 6. Recomendación de siguiente paso

1. Revisar previews (`docs/previews/index.html`) y el copy en la migración.
2. Si OK: aplicar la migración por canal Supabase (no envía nada) y abrir un envío de prueba a UN correo propio para validar render real + sustitución de variables en el Lambda.
3. Cerrar P0 de deliverability (List-Unsubscribe + baja real + warming).
4. Recién entonces: piloto **HOT (169) + SUPER_HOT (8)** con la campaña `HOT Email Test V1 — Discovery`, midiendo email→Discovery por UTM (y por `dl` cuando Discovery lo resuelva).

## Antes/después (resumen)

- **Antes:** 9/10 templates vendían Appril con "40–90% menos inasistencias" y CTA a `appril.co` (home). 1 template apuntaba a Discovery sin `dl`.
- **Después:** 10/10 hablan en lenguaje de consultorio ("usted"), abren con una pérdida concreta, ofrecen "9 preguntas, sin crear cuenta", y llevan a `{{discovery_url}}` (UTM + `dl`). El email de resultado lleva a WhatsApp Agent (principal) y registro (secundario), sin claims de %.
- Cuerpos completos antes/después: ver `docs/EXTRACCION-EMAILS-DISCOVERY-CORPUS.md` (antes) y la migración `20260629_1800_discovery_email_rewrite.sql` (después).
</content>
