# Appril Discovery — Fase 1 "v1-compat" — Notas de entrega (NO-código)

> **Estado:** documento de referencia. **NADA de lo aquí descrito se aplica/despliega todavía.**
> Acompaña a la migración SQL y a la edge function `send-discovery-email` (entregadas como archivos aparte).
> Objetivo de Fase 1: el rediseño del wizard pregunta en **semanal / moneda local / enums nuevos**; un adapter en frontend ya traduce a **valores canónicos** y los envía en *top-level* del payload de `submit_discovery_lead(input jsonb)`. **No se recalibra el score, no se cambian umbrales.** El backend solo añade una capa **defensiva** de normalización + persistencia de nuevos campos comerciales + disparo de email server-side.

- Supabase `project_id`: `hwiocriejizjdqqcfrsj`
- RPC de entrada: `public.submit_discovery_lead(input jsonb)` (SECURITY DEFINER)
- Scoring: `public.calculate_discovery_score(p_q_volume,p_q_lost,p_q_intent,p_q_urgency,p_q_ticket,p_q_digital)` → `jsonb`
- Umbrales (sin cambios): `>=75 SUPER_HOT`, `>=50 HOT`, `>=25 WARM`, `else COLD`

---

## 1. Payload de ejemplo: ANTES vs DESPUÉS (lead Colombia / COP / HOT)

Mismo profesional, mismo wizard. La diferencia es **si el adapter del frontend corrió o no** antes de armar el *top-level* del payload.

### 1.1 ANTES — rediseño "crudo" (colapsa el score)

El wizard nuevo manda directamente los enums **nuevos / semanales / en moneda local** en el top-level. `calculate_discovery_score` solo mapea enums canónicos: todo valor desconocido cae al `ELSE => 0` (fallo silencioso). El score se **colapsa a COLD** aunque el lead sea HOT.

```json
{
  "workspace_slug": "appril",
  "full_name": "Dra. Valentina Restrepo",
  "whatsapp_e164": "+573001234567",
  "email": "valentina.restrepo@example.com",
  "specialization": "Dermatología",
  "clinic_name": "Clínica Piel Sana",
  "city": "Medellín",
  "country": "CO",
  "consent": true,

  "monthly_appointments_range": "weekly_51_100",
  "lost_appointments_range": "weekly_6_10",
  "scheduling_method": "whatsapp",
  "average_ticket_range": "cop_150_250k",
  "desired_next_step": "demo",
  "urgency": "alta",

  "selected_currency": "COP",
  "utm_source": "meta",
  "utm_medium": "paid_social",
  "utm_campaign": "discovery_co_hot",
  "landing_url": "https://appril.co/diagnostico?utm_source=meta"
}
```

**Resultado con la función actual (sin capa defensiva):**

| key de score | valor recibido | ¿canónico? | aporte |
|---|---|---|---|
| `q_volume` | `weekly_51_100` | NO → ELSE | **0** |
| `q_lost` | `weekly_6_10` | NO → ELSE | **0** |
| `q_ticket` | `cop_150_250k` | NO → ELSE | **0** |
| `q_digital` | `whatsapp` | sí | (su peso) |
| `q_intent` | `demo` | sí | (su peso) |
| `q_urgency` | `alta` | sí | (su peso) |

→ **score colapsado** (3 de 6 dimensiones en 0). Un lead que debería ser SUPER_HOT/HOT cae a **WARM/COLD**. Este es el bug que Fase 1 neutraliza.

### 1.2 DESPUÉS — con adapter en frontend (top-level canónico) + backend defensivo

El adapter del frontend traduce a canónico **antes** de enviar. El backend, además, vuelve a normalizar de forma defensiva (paridad con el adapter) y registra `score_input_debug`.

> **Ticket (verificado):** `ticket_midpoint_usd = 50` → bucket canónico **`50_100`**. La regla del adapter es de cota superior exclusiva (`25_50<50`, `50_100<100`): 50 **no** es `<50`, así que cae en `50_100` (rango `[50, 100)`). Ver nota de frontera en 1.3.

```json
{
  "workspace_slug": "appril",
  "full_name": "Dra. Valentina Restrepo",
  "whatsapp_e164": "+573001234567",
  "email": "valentina.restrepo@example.com",
  "specialization": "Dermatología",
  "clinic_name": "Clínica Piel Sana",
  "city": "Medellín",
  "country": "CO",
  "consent": true,

  "monthly_appointments_range": "gt_300",
  "lost_appointments_range": "gt_20",
  "scheduling_method": "whatsapp",
  "average_ticket_range": "50_100",
  "desired_next_step": "demo",
  "urgency": "alta",

  "selected_currency": "COP",
  "risk_dominant": "no_shows",
  "risk_evidence": {
    "no_shows": { "weekly": 8, "annualized": 416, "weight": 0.42 },
    "cancellations": { "weekly": 3, "annualized": 156, "weight": 0.21 },
    "whatsapp_overload": { "hours_week": 6, "weight": 0.18 }
  },
  "main_pain": "no_shows",
  "main_pains": ["no_shows", "whatsapp_overload", "cancellations"],
  "recommended_action": "recover_spaces",
  "primary_cta_key": "activate_trial",
  "primary_cta_label": "Activar mi mes gratis de Appril",

  "frontend_calculations": {
    "currency": {
      "selected_currency": "COP",
      "fx_rate_to_usd": 0.00025,
      "locale": "es-CO",
      "ticket_midpoint_local": 200000,
      "ticket_midpoint_usd": 50
    },
    "annual_lost_revenue_local": 41600000,
    "annual_lost_revenue_usd": 10400,
    "hidden_cost_total_local": 7200000
  },

  "findings": {
    "risk_dominant": "no_shows",
    "risk_evidence": {
      "no_shows": { "weekly": 8, "annualized": 416 }
    },
    "first_recommended_step": "recover_spaces",
    "agenda_maturity_level": "reactiva"
  },

  "legacy_answers": {
    "monthly_appointments_range": "weekly_51_100",
    "lost_appointments_range": "weekly_6_10",
    "scheduling_method": "whatsapp",
    "average_ticket_range": "cop_150_250k",
    "desired_next_step": "demo",
    "urgency": "alta"
  },

  "utm_source": "meta",
  "utm_medium": "paid_social",
  "utm_campaign": "discovery_co_hot",
  "landing_url": "https://appril.co/diagnostico?utm_source=meta"
}
```

> **Nota sobre `legacy_answers`:** en el payload aparece en *top-level* porque es lo que arma el frontend; el backend lo **anida** en `frontend_calculations.legacy_answers` al persistir (no hay columna dedicada). Ver 2.2.

**Trazas de la capa defensiva (`score_input_debug`, persistida en `discovery_leads`):**

```json
{
  "received": {
    "q_volume": "gt_300",
    "q_lost": "gt_20",
    "q_ticket": "50_100",
    "q_digital": "whatsapp",
    "q_intent": "demo",
    "q_urgency": "alta"
  },
  "normalized": {
    "q_volume": "gt_300",
    "q_lost": "gt_20",
    "q_ticket": "50_100",
    "q_digital": "whatsapp",
    "q_intent": "demo",
    "q_urgency": "alta"
  },
  "warnings": [],
  "scoring_version": "discovery_v1_compat"
}
```

> Si por cualquier motivo llegara un valor **nuevo** al top-level (p.ej. `weekly_51_100`), el backend lo normaliza con las mismas tablas del adapter y deja `warnings: ["q_volume: normalized weekly_51_100 -> gt_300"]`. Si llega un valor **desconocido** (no canónico y no mapeable), se registra `warnings: ["q_ticket: UNKNOWN value 'cop_X' could not be normalized"]` y **no** se deja caer al `ELSE => 0` silencioso (se usa el último canónico conocido o `variable`, y queda auditable).

### 1.3 Tabla de equivalencias usada (paridad adapter ⇄ backend defensivo)

| Dimensión | Valor nuevo (wizard) | → Canónico |
|---|---|---|
| Volumen | `weekly_lt_15` / `weekly_15_50` / `weekly_51_100` / `weekly_100_plus` | `30_80` / `81_150` / `gt_300` / `gt_300` |
| Perdidas | `weekly_none` / `weekly_1_2` / `weekly_3_5` / `weekly_6_10` / `weekly_10_plus` / `no_medido` | `0_2` / `6_10` / `11_20` / `gt_20` / `gt_20` / `no_medido` |
| Agenda | `whatsapp` / `digital_calendar` / `excel` / `papel` / `scheduling_software` / `clinical_system` / `institution_system` / `external_portal` / `not_centralized` | `whatsapp` / `software_basico` / `excel` / `papel` / `software_basico` / `software_avanzado` / `software_avanzado` / `software_basico` / `sin_sistema` |
| Ticket (por `ticket_midpoint_usd`) | `<10` / `<25` / `<50` / `<100` / `>=100` / `<=0` | `lt_10` / `10_25` / `25_50` / `50_100` / `gt_100` / `variable` |

> **Semántica de frontera del ticket (cota superior exclusiva):** cada bucket cubre `[límite_inferior, límite_superior)`. Es decir, el límite superior **no** pertenece al bucket: `lt_10 = (-∞,10)`, `10_25 = [10,25)`, `25_50 = [25,50)`, `50_100 = [50,100)`, `gt_100 = [100,∞)`, `variable = (-∞,0]`. Por eso `ticket_midpoint_usd = 50` cae en **`50_100`** (no en `25_50`). El backend defensivo aplica exactamente la misma regla que el adapter del frontend.

> El score **se calcula con el canónico**, idéntico a hoy → **backward-compatible**: un payload que ya venía canónico produce exactamente el mismo score.

---

## 2. Ejemplos de columnas/JSONB persistidos

### 2.1 `raw_answers` (lo que el wizard capturó, sin traducir)

```json
{
  "step_volume": { "question": "¿Cuántas citas atiendes por semana?", "value": "weekly_51_100" },
  "step_lost": { "question": "¿Cuántas citas pierdes por semana (no-show + cancelaciones)?", "value": "weekly_6_10" },
  "step_method": { "question": "¿Cómo agendas hoy?", "value": "whatsapp" },
  "step_ticket": { "question": "Valor promedio de una cita", "value_local": 200000, "currency": "COP" },
  "step_next": { "question": "¿Qué te gustaría hacer ahora?", "value": "demo" },
  "step_urgency": { "question": "¿Qué tan urgente es resolverlo?", "value": "alta" }
}
```

> **Nota de coherencia (ilustrativa):** el bucket declarado `weekly_6_10` (6–10 citas perdidas/semana) mapea a `gt_20` canónico. El desglose de `risk_evidence` (8 no-shows + 3 cancelaciones/semana ≈ 11) es un **ejemplo** de evidencia, no una validación cruzada estricta del bucket; las cifras del bloque `risk_evidence`/`annual_lost_revenue` son realistas pero no datos reales.

### 2.2 `legacy_answers` (alias de los valores nuevos antes del adapter — auditoría)

```json
{
  "monthly_appointments_range": "weekly_51_100",
  "lost_appointments_range": "weekly_6_10",
  "scheduling_method": "whatsapp",
  "average_ticket_range": "cop_150_250k",
  "desired_next_step": "demo",
  "urgency": "alta",
  "captured_in_version": "redesign_2026q2"
}
```

> Se persiste dentro de `raw_answers.legacy_answers` o en `frontend_calculations.legacy_answers` (no hay columna dedicada; ambos son JSONB existentes). **Recomendado: `frontend_calculations.legacy_answers`** para mantener `raw_answers` "tal cual el wizard". El backend es quien hace ese anidado, aunque el frontend lo envíe en top-level.

### 2.3 `frontend_calculations.currency`

```json
{
  "selected_currency": "COP",
  "fx_rate_to_usd": 0.00025,
  "locale": "es-CO",
  "symbol": "$",
  "ticket_midpoint_local": 200000,
  "ticket_midpoint_usd": 50,
  "computed_at": "2026-06-29T14:05:00Z"
}
```

> Todas las cifras del email se renderizan en `selected_currency` usando `fx_rate_to_usd` para convertir desde/hacia USD. **Argentina queda fuera del tráfico HOT inicial**: si `selected_currency === "ARS"` o `country === "AR"`, se cae a USD o se excluye del envío HOT (ver Riesgos).

### 2.4 `findings`

```json
{
  "risk_dominant": "no_shows",
  "risk_evidence": {
    "no_shows": { "weekly": 8, "annualized": 416, "weight": 0.42 },
    "cancellations": { "weekly": 3, "annualized": 156, "weight": 0.21 },
    "whatsapp_overload": { "hours_week": 6, "weight": 0.18 }
  },
  "first_recommended_step": "recover_spaces",
  "agenda_maturity_level": "reactiva",
  "main_pains": ["no_shows", "whatsapp_overload", "cancellations"],
  "headline": "Se te pueden estar escapando ~416 citas al año por no-shows"
}
```

---

## 3. PDF — decisión documentada (Fase 2, NO bloquea Fase 1)

**Decisión:** el PDF **no** se construye en Fase 1. Se entrega el diagnóstico por **email HTML** (compatible Gmail/Outlook). El PDF queda planificado para Fase 2 sin bloquear el lanzamiento.

### 3.1 Estructura sugerida del PDF (1–2 páginas)

1. Encabezado: marca Appril + nombre del profesional + fecha.
2. "Tu diagnóstico de agenda" — score y clasificación (SUPER_HOT/HOT/WARM/COLD) en lenguaje no técnico ("Tu agenda está en riesgo alto/medio/bajo").
3. Bloque de **riesgo dominante** (`risk_dominant`) con evidencia (`risk_evidence`): no-shows / cancelaciones / sobrecarga WhatsApp.
4. **Costo oculto anual** en moneda seleccionada (`annual_lost_revenue_local`, `hidden_cost_total_local`).
5. **Próximo paso recomendado** (`first_recommended_step` / `recommended_action`) + CTA ("Activar mi mes gratis de Appril").
6. Pie: contacto y disclaimer (estimaciones basadas en respuestas declaradas).

### 3.2 Datos requeridos (ya disponibles, sin nuevas preguntas)

- `discovery_leads`: `score`, `lead_classification`, `marketing_segment`, `findings`, `frontend_calculations.currency`, `annual_lost_revenue`, `hidden_cost_total`, `recommended_action`, `primary_cta_*`, `full_name`, `specialization`, `clinic_name`.
- Todo el PDF se renderiza con los **mismos datos** del email → una sola fuente de verdad.

### 3.3 Storage sugerido (Supabase Storage)

- Bucket **privado** `discovery-pdfs`.
- Path: `discovery-pdfs/{workspace_id}/{discovery_lead_id}.pdf`.
- Acceso vía **signed URL** (TTL 7 días) generada por la edge function; nunca público.
- Columna nueva en Fase 2: `discovery_leads.pdf_path text` + `pdf_generated_at timestamptz`.

### 3.4 Generación y reenvío

- Generación: edge function `generate-discovery-pdf` (Fase 2) usando un renderer HTML→PDF headless (p.ej. `@react-pdf` server-side o un servicio de render), disparada **después** del insert (mismo patrón pg_net que el email, o encolada).
- Reenvío: endpoint/edge `resend-discovery` que: (a) si existe `pdf_path`, regenera signed URL y reenvía email con adjunto/enlace; (b) si no existe, lo genera on-demand. Idempotente por `discovery_lead_id`.
- El email de Fase 1 ya deja el **gancho**: incluir luego el enlace al PDF sin rediseñar la plantilla.

---

## 4. Riesgos pendientes

| # | Riesgo | Prob | Impacto | Mitigación |
|---|---|---|---|---|
| R1 | `pg_net` no está instalada hoy; el trigger on-insert no dispara sin habilitarla. | Media | Alto (no se envía ningún email) | La migración hace `create extension if not exists pg_net with schema extensions;`. Si la política del proyecto lo bloquea, **fallback documentado**: `front_invoke` (el front llama `supabase.functions.invoke('send-discovery-email')`). `message_queue` NO sirve como ruta primaria: no existe drainer de email (`automation_tick` solo produce, nadie consume). |
| R2 | Llega un valor **nuevo no mapeado** al top-level → score colapsa al `ELSE => 0`. | Baja (adapter ya traduce) | Alto | Capa defensiva en backend con **paridad** del adapter + `score_input_debug.warnings`; valor desconocido NO cae a 0 silencioso. Alerta operativa al ver warnings. |
| R3 | Doble envío de email (reintento de pg_net, reinsert, replay). | Media | Medio (spam al lead, daño de marca) | Columna de control `email_sent_at` + guard idempotente en la edge (no enviar si ya hay `email_sent_at`). Trigger solo dispara cuando `email_sent_at IS NULL`. |
| R4 | Credenciales AWS SES no seteadas en el entorno de la edge. | Media | Alto | Reusar patrón `inbox-send` (Deno.env AWS creds). Smoke test obligatorio antes de tráfico. Remitente desde `workspace_integrations` (channel='email', status activo); `from_email`/`from_name`. |
| R5 | Formato E.164 inválido en `whatsapp_e164` (ya conocido en memoria del CRM). | Media | Medio (no afecta email, sí WA encolado) | Validación previa; el email no depende del teléfono. WA queda gobernado por el guard endurecido (`20260626_1400_harden_whatsapp_guard.sql`). |
| R6 | Argentina/ARS sin FX confiable distorsiona cifras del email. | Media | Medio | **Excluir AR del tráfico HOT inicial**; si entra, renderizar en USD (`fallback USD`). Flag por `country/selected_currency`. |
| R7 | Render del email roto en Outlook (CSS no inline / divs en vez de tablas). | Media | Medio | HTML server-side con **tablas + estilos inline**, preheader oculto, sin flexbox/grid. QA en Gmail web/app y Outlook desktop/web. |
| R8 | `track_discovery_event` no whitelista `micro_win_viewed`/`mini_win_viewed` (sí `gift_viewed`). | Alta | Bajo | Eventos no whitelistados se ignoran silenciosamente; documentar y, si se necesitan, ampliar whitelist en migración aparte (fuera de Fase 1). |
| R9 | Falla parcial dentro de `submit_discovery_lead` (EXCEPTION WHEN OTHERS devuelve `{ok:false}`) oculta la causa raíz. | Media | Medio | Persistir contexto en `score_input_debug` y `lead_events` antes de cálculos pesados; loggear `error` con suficiente detalle. |
| R10 | Persistir señales de CTA en columnas inexistentes (`commercial_intent`, `cta_intent` no existen en `leads_master`). | Alta | Medio | La migración **añade** `leads_master.commercial_intent`, `cta_intent` y `discovery_leads.cta_clicked` + `legacy_lead_score`/`scoring_version`/`score_input_debug`. Sin esto, el UPDATE de `cta_clicked` falla. |

---

## 5. Instrucciones de DEPLOY (ordenadas) — **NADA se aplica aún**

> Runbook de referencia. **No ejecutar como parte de esta entrega.** Todo es backward-compatible: los valores canónicos siguen produciendo el mismo score. Ejecutar en este orden **solo cuando se autorice el deploy**.

1. **Revisión de artefactos (dry run).**
   - Leer la migración SQL y la edge `send-discovery-email`. Confirmar que `CREATE OR REPLACE` de `submit_discovery_lead` y `calculate_discovery_score` conserva firmas y comportamiento canónico.

2. **Aplicar migración** (añade columnas + capa defensiva + extensión + trigger):
   ```bash
   supabase db push --project-ref hwiocriejizjdqqcfrsj
   # o aplicar el archivo de migración con tu flujo habitual
   ```
   - Verifica que `create extension if not exists pg_net with schema extensions;` no fue bloqueado.
   - Verifica columnas nuevas:
     `discovery_leads`: `selected_currency, risk_dominant, risk_evidence, main_pain, main_pains, recommended_action, primary_cta_key, primary_cta_label, legacy_lead_score, scoring_version, score_input_debug, cta_clicked, email_sent_at`.
     `leads_master`: `commercial_intent, cta_intent`.

3. **Setear secrets/env de la edge (AWS SES + service role)** antes de desplegarla:
   ```bash
   supabase secrets set \
     AWS_ACCESS_KEY_ID=... \
     AWS_SECRET_ACCESS_KEY=... \
     AWS_REGION=us-east-1 \
     SES_FROM_EMAIL="Appril <diagnostico@appril.co>" \
     --project-ref hwiocriejizjdqqcfrsj
   # SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY ya existen en el runtime de Functions
   ```

4. **Deploy de la edge function:**
   ```bash
   supabase functions deploy send-discovery-email --project-ref hwiocriejizjdqqcfrsj
   ```

5. **Configurar el trigger pg_net** (ya creado por la migración) con la URL real de la función + header `Authorization: Bearer <service_role>`. Si se usa `vault`/setting para la URL y el token, setearlos ahora.

6. **Smoke test (sin tráfico real):**
   - Insertar un lead de prueba canónico vía RPC (`select submit_discovery_lead('{...}'::jsonb);`) con un email interno.
   - Confirmar: fila en `discovery_leads`, `score`/`lead_classification` correctos, `score_input_debug` con `warnings: []`, `email_sent_at` poblado, email recibido y renderizado OK en Gmail y Outlook.
   - Probar el caso ANTES (valores nuevos al top-level) → confirmar normalización defensiva y warnings, score NO colapsado.
   - Validar el **borde del ticket**: `ticket_midpoint_usd = 50` debe normalizar a `50_100` (no `25_50`); `49.99` → `25_50`; `100` → `gt_100`.
   - Probar `cta_clicked` → confirmar `leads_master.commercial_intent='high'` y `cta_intent` correcto.

7. **Habilitar tráfico** (Meta/landing) solo tras smoke test verde. **Excluir AR del segmento HOT.**

---

## 6. Plan de ROLLBACK (por artefacto)

> Cada artefacto revierte de forma independiente. El orden de rollback es inverso al de deploy.

| Artefacto | Rollback | Notas |
|---|---|---|
| **Trigger pg_net** (`AFTER INSERT on discovery_leads`) | `DROP TRIGGER IF EXISTS trg_discovery_send_email ON public.discovery_leads;` (+ `DROP FUNCTION IF EXISTS public.fn_discovery_send_email() CASCADE;` si aplica) | Detiene el disparo de email sin tocar el resto. Es la palanca de emergencia #1. |
| **Edge `send-discovery-email`** | Convertir en **no-op**: redeploy de una versión que responde `200 {ok:true, skipped:true}` sin enviar; o `supabase functions delete send-discovery-email`. | No-op evita 5xx en el trigger mientras se decide. |
| **`submit_discovery_lead(input jsonb)`** | `CREATE OR REPLACE FUNCTION ... ` con la **versión previa** (guardada en `rollback/submit_discovery_lead_prev.sql`). | Revertir la capa defensiva. El overload legacy positional no se toca. |
| **`calculate_discovery_score`** | `CREATE OR REPLACE` a la versión previa (`rollback/calculate_discovery_score_prev.sql`). | Solo si se hubiera tocado; en Fase 1 idealmente queda intacta (la normalización vive en `submit_discovery_lead`). |
| **Columnas nuevas** (`discovery_leads.*`, `leads_master.commercial_intent/cta_intent`) | **Opcional** `ALTER TABLE ... DROP COLUMN IF EXISTS ...`. Recomendado **dejarlas** (son aditivas y nullables → no rompen nada). | Solo dropear si exige limpieza total. Dropear `score_input_debug`/`legacy_lead_score` pierde auditoría. |
| **Extensión `pg_net`** | `DROP EXTENSION IF EXISTS pg_net;` (solo si nada más la usa). | Normalmente **no** revertir: es infra compartida. Antes de dropear, verificar dependencias: `select * from pg_depend where refobjid = 'extensions.pg_net'::regclass;`. |

**Pre-requisito de rollback seguro:** los archivos `rollback/submit_discovery_lead_prev.sql` y `rollback/calculate_discovery_score_prev.sql` deben capturarse **antes** de aplicar la migración (snapshot del `pg_get_functiondef` actual). Sin esos snapshots, el revert de la función no es reproducible.

**Secuencia mínima de pánico (corta el envío sin perder datos):**
```sql
DROP TRIGGER IF EXISTS trg_discovery_send_email ON public.discovery_leads;
```
Esto detiene los emails de inmediato; `submit_discovery_lead` sigue insertando con score correcto.

---

## 7. Checklist de invariantes (para QA)

- [ ] Un payload **ya canónico** produce el **mismo** `score`/`segment`/`lead_classification` que antes de Fase 1.
- [ ] `calculation_version` sigue siendo `'v2'`; se añade `scoring_version='discovery_v1_compat'` y `legacy_lead_score`.
- [ ] No se cambian umbrales (`75/50/25`).
- [ ] `score_input_debug` se persiste siempre, con `warnings` vacío en el camino feliz.
- [ ] **Ticket por `ticket_midpoint_usd`** respeta la cota superior exclusiva: `50 → 50_100`, `49.99 → 25_50`, `100 → gt_100`, `<=0 → variable`.
- [ ] Dedup por phone y no-downgrade de `marketing_segment` intactos.
- [ ] El email se dispara **server-side** (trigger), no depende del navegador; `front_invoke` solo como fallback documentado.
- [ ] Idempotencia de email garantizada por `email_sent_at`.
- [ ] AR excluido del tráfico HOT (USD fallback).
