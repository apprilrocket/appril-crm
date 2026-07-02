# Checklist único de pre-lanzamiento · Emails → Discovery

> Fuente única de verdad para pasar de "todo preparado" a "primer envío real".
> **Regla de oro:** nada de esto envía solo. Los envíos solo ocurren cuando lanzás una
> campaña aprobada (`campaigns.approved_at`) que encola en `message_queue`.
> Owner: **[TÚ]** = vos · **[CLAUDE]** = puedo hacerlo yo si lo pedís · **[AMBOS]**.
> Estado al 2026-06-29: el remitente del Lambda ya está unificado (✅); el resto está en archivos sin aplicar.

---

## FASE 0 · Lo ya hecho (no requiere acción)
- [x] **Lambda `appril-crm-sender`**: `SES_FROM_EMAIL`=`SES_REPLY_TO`=`hola@appril.co` (aplicado por CLI, 13 vars intactas).
- [x] **Copy reescrito** de los 10 templates + email de resultado (en migración / código).
- [x] **`dl_token`** + hidratación `discovery_url`/`unsubscribe_url` (en migración).
- [x] **List-Unsubscribe** one-click en `appril-sender/src/ses.ts` (en código).
- [x] **Endpoint `email-unsubscribe`** (en código + `config.toml verify_jwt=false`).
- [x] **Supabase**: verificado que NO hay overrides `DISCOVERY_FROM_EMAIL`/`INBOX_FROM_EMAIL`.

---

## FASE 1 · Aplicar backend (en este orden — hay dependencias)

### 1.1 [TÚ/CLAUDE] Aplicar la migración de templates  ⟶ no envía nada
`supabase/migrations/20260629_1800_discovery_email_rewrite.sql`
- Por tu canal Supabase habitual (o `supabase db push --project-ref hwiocriejizjdqqcfrsj`).
- **Verificar:**
  ```sql
  select count(*) from public.leads_master where dl_token is null;        -- esperado: 0
  select template_key, subject from public.message_templates
    where channel='email' order by template_key;                          -- 10 subjects nuevos
  ```

### 1.2 [TÚ/CLAUDE] Deploy del endpoint de baja  ⟶ debe existir ANTES de cualquier envío
```bash
supabase functions deploy email-unsubscribe --project-ref hwiocriejizjdqqcfrsj
```
- **Verificar (sin dar de baja a nadie real):**
  - GET en navegador: `https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/email-unsubscribe?dl=test` → debe mostrar página "Enlace inválido" (200), no 401.
  - Con un **lead de prueba**: tomar su `dl_token`, hacer POST y confirmar `can_email=false`:
    ```bash
    curl -X POST "https://hwiocriejizjdqqcfrsj.supabase.co/functions/v1/email-unsubscribe?dl=<DL_DE_PRUEBA>"
    ```
    ```sql
    select can_email, unsubscribed_email from leads_master where dl_token='<DL_DE_PRUEBA>';
    ```
    (revertir el lead de prueba luego: `update leads_master set can_email=true, unsubscribed_email=false where dl_token='<DL_DE_PRUEBA>';`)

### 1.3 [TÚ] Deploy del Lambda sender  ⟶ activa el header List-Unsubscribe
```bash
cd appril-sender && npm run deploy:sender
```
- El env ya está; esto sube el **código** nuevo de `ses.ts` (MIME crudo + List-Unsubscribe).
- **Verificar:** `npm run build` sin errores antes de deploy (ya validado con `tsc`).

### 1.4 [TÚ/CLAUDE] Deploy de las edge del remitente + copy de resultado  ⟶ go-live del copy
```bash
supabase functions deploy send-discovery-email --project-ref hwiocriejizjdqqcfrsj
supabase functions deploy inbox-send --project-ref hwiocriejizjdqqcfrsj
```
- Esto pone From `hola@appril.co` Y sube el **email de resultado reescrito** (WhatsApp primario).

---

## FASE 2 · Deliverability P0 (AWS/DNS — [TÚ])  ⟶ bloquea el blast masivo
- [ ] `hola@appril.co` verificado en SES:
  ```bash
  aws ses get-identity-verification-attributes --identities appril.co hola@appril.co --region us-east-1
  ```
- [ ] **DKIM** Success + CNAMEs publicados:
  ```bash
  aws ses get-identity-dkim-attributes --identities appril.co --region us-east-1
  ```
- [ ] **SPF**: TXT de `appril.co` (o del MAIL FROM) incluye `include:amazonses.com`.
- [ ] **DMARC**: existe TXT en `_dmarc.appril.co` (al menos `v=DMARC1; p=none; rua=mailto:...`).
- [ ] **Recepción**: podés leer la bandeja de `hola@appril.co` (replies y respuestas a campañas caen ahí).
- [ ] **Warming/volumen**: plan para no mandar 12k WARM de golpe (empezar chico, subir gradual).

---

## FASE 3 · Prueba de humo (antes del primer envío real — [AMBOS])
- [ ] Enviar **un** correo de prueba a una dirección propia (vía `send_test` del MCP de campañas, o una campaña aprobada apuntada a un solo lead de test).
- [ ] En el correo recibido, verificar:
  - [ ] **From** y **Reply-To** = `hola@appril.co`.
  - [ ] Aparece el botón **"Unsubscribe"** de Gmail (header List-Unsubscribe one-click).
  - [ ] El CTA lleva a `discovery.appril.co/...&dl=<token>` (link completo, no `{{discovery_url}}` literal).
  - [ ] Footer "Cancelar suscripción" → página de confirmación → al confirmar, el lead queda `can_email=false`.
  - [ ] Sin claims de %, "usted", copy de consultorio.
- [ ] Responder el correo de prueba → llega a `hola@appril.co`.

---

## FASE 4 · Atribución (no bloquea el piloto, sí el escalado)
- [ ] **Campaña** (ya funciona): los UTM (`utm_campaign`/`utm_content`) llegan a `discovery_leads.utm_*`.
- [ ] **Por lead (P1)**: que el **backend de Discovery lea `dl`** y lo guarde (hoy `dl` viaja en la URL pero Discovery no lo resuelve). Mientras tanto, atribución solo a nivel campaña.

---

## FASE 5 · Go-live del piloto (controlado — [TÚ] aprobás)
- [ ] Elegir la campaña piloto: **`HOT Email Test V1 — Discovery`** (segmento HOT, 169) + opcional SUPER_HOT (8). **No WARM todavía.**
- [ ] **Aprobación humana**: setear `campaigns.approved_at` (la función `crm_launch_campaign` rechaza si está null).
- [ ] Lanzar SOLO el piloto. Confirmar que encoló lo esperado:
  ```sql
  select status, count(*) from message_queue where campaign_id='<ID>' group by status;
  ```
- [ ] **Monitorear primeras horas**: opens / clicks / **bounces** / **complaints** / unsubscribes / `discovery_started`.
  ```sql
  select event_type, count(*) from lead_events
    where created_at > now() - interval '6 hours' group by event_type order by 2 desc;
  ```
- [ ] **Criterio de aborto:** si bounce > ~5% o aparecen complaints → pausar y revisar lista/dominio antes de seguir.
- [ ] Si todo OK: recién entonces planear **WARM** (12k) con warming gradual.

---

## Rollbacks rápidos
- **Remitente Lambda** → volver `SES_REPLY_TO=mauricio@todoc.co` (ver `docs/RUNBOOK-remitente-unificado-aws.md`).
- **Templates** → la migración es reversible reaplicando los cuerpos previos (ver `docs/EXTRACCION-EMAILS-DISCOVERY-CORPUS.md`, sección "antes").
- **Edge functions** → redeploy de la versión anterior.
- **Campaña** → no se puede "des-enviar"; por eso el piloto es chico y con criterio de aborto.

---

## Estado de archivos (todo en repo, revisable)
| Pieza | Archivo | Aplicado |
|---|---|---|
| Templates + dl_token + hidratación | `supabase/migrations/20260629_1800_discovery_email_rewrite.sql` | ❌ |
| Endpoint baja | `supabase/functions/email-unsubscribe/index.ts` (+ `config.toml`) | ❌ |
| List-Unsubscribe | `appril-sender/src/ses.ts` | ❌ |
| Remitente edge | `send-discovery-email/index.ts`, `inbox-send/index.ts` | ❌ (código listo) |
| Remitente Lambda (env) | AWS `appril-crm-sender` | ✅ |
| MCP vars | `mcp/src/lib/campaigns.ts` | ❌ |
| Previews | `docs/previews/*.html` | n/a |
