# ses-webhook — eventos de SES (Fase C)

Sustituye la ruta `/webhook/ses` del Lambda `appril-crm-webhook`.

## Estado
- **live** desde 2026-07-09 (secret `SES_WEBHOOK_MODE`; `shadow` = valida y loguea sin escribir).
- Suscriptor único del topic SNS `ses-events-appril-crm`. El Lambda fue des-suscrito.
- Verificado en prod: `delivered`/`opened` escritos 1:1 igual que el Lambda (correlación por `ses_message_id`),
  y el Lambda quedó en **cero invocaciones**.

## Qué endurece respecto del Lambda
El Lambda **no validaba nada**:
1. Sin firma SNS → un POST forjado con `Complaint`/`Bounce` ponía `can_email=false` a leads arbitrarios.
2. `fetch(SubscribeURL)` a cualquier URL recibida → SSRF.

Aquí: firma RSA verificada contra el certificado de AWS (X.509 → SPKI, SHA-1/SHA-256 según
`SignatureVersion`), `SigningCertURL`/`SubscribeURL` restringidos a `sns.<region>.amazonaws.com`,
y allowlist de `TopicArn` (`SES_WEBHOOK_TOPIC_ARN`).

## Reversa
1. `supabase secrets set SES_WEBHOOK_MODE=shadow --project-ref hwiocriejizjdqqcfrsj`
2. `aws sns subscribe --topic-arn arn:aws:sns:us-east-1:516426598004:ses-events-appril-crm \
     --protocol https --notification-endpoint https://zkb9p2z5je.execute-api.us-east-1.amazonaws.com/webhook/ses --region us-east-1`

## Criterio para la Fase D (apagar AWS)
El Lambda `appril-crm-webhook` debe permanecer en **0 invocaciones durante 24h**. Comprobación:

```
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
  --dimensions Name=FunctionName,Value=appril-crm-webhook \
  --start-time "$(date -u -v-24H +%Y-%m-%dT%H:%M:%S)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --period 3600 --statistics Sum --region us-east-1 --query 'Datapoints[].Sum'
```

Rutas del Lambda y su estado (auditoría 2026-07-09, todos los repos de ~/dev):
- `/webhook/ses` — reemplazada por esta función.
- `/webhook/whatsapp` — **muerta** desde la Fase A (Meta ya no entrega ahí; cero invocaciones durante
  conversaciones reales). El default de `CRM_WEBHOOK_URL` en appril-web ya no apunta aquí (v50).
- `/webhook/external` — **muerta**: `webhook_events` no tiene ningún consumidor en ningún repo.

Fase D pendiente: borrar las 2 Lambdas, API Gateway, EventBridge y el rol IAM →
**el service_role del CRM deja de vivir fuera de Supabase** (endurecimiento pendiente desde junio).
