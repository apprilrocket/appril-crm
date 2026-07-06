# Cómo desplegar appril-crm

Hay **dos canales separados**. No los mezcles.

## 1. Frontend (Next.js en `src/`) → SOLO por Git/Vercel

El frontend se despliega **únicamente** por la integración de Git de Vercel:

```
commit  →  push  →  PR  →  merge a main  →  Vercel despliega solo
```

**Nunca** uses `vercel --prod` desde la CLI.

> ⚠️ **Por qué no la CLI:** Vercel atribuye el deploy al **autor de git del commit**, no a
> la cuenta con la que se ejecuta. El proyecto exige que ese email corresponda a una cuenta
> de Git conocida del equipo. Un deploy con un email no vinculado queda **bloqueado**
> ("The deployment was blocked because the commit email … could not be matched to a Git
> account"). Producción no cambia (el deploy bloqueado nunca toma el alias).

### Identidad de git requerida

Los commits deben ir firmados con un email **verificado en la cuenta de GitHub** que tiene
acceso a `apprilrocket/appril-crm` (y al equipo de Vercel):

```bash
git config user.email admin@appril.co   # o el email verificado en esa cuenta de GitHub
```

Si un commit ya quedó con otro email, reescribe el autor antes de abrir el PR
(`git commit --amend --author="Nombre <email-correcto>"`) o el merge se bloqueará igual.

## 2. Backend → por el canal de Supabase (NO por Vercel/Git)

Proyecto Supabase: `hwiocriejizjdqqcfrsj`.

### Migraciones / RPC / DDL

```bash
# Aplicar SOLO esa migración vía el MCP de Supabase (apply_migration),
# el SQL editor del dashboard, la Management API o psql directo.
```

> ⚠️ **`supabase db push` NO funciona en este repo.** El historial de migraciones
> del remoto usa IDs de 14 dígitos que **no correlacionan** con los nombres de
> archivo locales (`AAAAMMDD_HHMM_nombre`). `db push` intenta reconciliar por
> nombre, no encaja, y falla / propone aplicar cosas equivocadas. Aplica cada
> migración a mano (MCP / SQL editor / Management API) — nunca `db push`.

Mantén `supabase/schema.sql` sincronizado con la migración (es el baseline de referencia).

### Edge functions

```bash
# Desplegar SIEMPRE con --use-api (bandera obligatoria en este repo):
supabase functions deploy inbox-send      --use-api
supabase functions deploy whatsapp-agent  --use-api
supabase functions deploy demo-callback   --use-api
```

> ⚠️ **`--use-api` es obligatorio.** El bundler local del CLI (2.72.7) rompe con el
> `deno.lock` v5 de estas funciones (incompatibilidad de versión de lockfile).
> `--use-api` empaqueta y despliega vía la Management API en vez del bundler local
> y evita el error. Sin la bandera el deploy falla en el bundling.

## Orden recomendado para un cambio full-stack

1. **Backend primero** (migración + edge functions): suele ser retrocompatible
   (p. ej. columnas nuevas al final de un RETURNS TABLE → el frontend viejo las ignora).
2. **Frontend después** por Git: commit → push → PR → merge a `main`.

Así el sistema nunca queda en un estado roto entre ambos deploys.
