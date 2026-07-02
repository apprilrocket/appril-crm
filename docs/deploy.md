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
# Opción A (recomendada para un cambio aislado): aplicar solo esa migración
#   vía el MCP de Supabase (apply_migration) o psql.
# Opción B: supabase db push  -- CUIDADO: aplica TODAS las migraciones locales
#           pendientes, no solo la tuya. Revisa `supabase migration list` antes.
```

Mantén `supabase/schema.sql` sincronizado con la migración (es el baseline de referencia).

### Edge functions

```bash
# Quita el lockfile antes (rompe el bundler del deploy; ya está en .gitignore):
rm -f supabase/functions/deno.lock

supabase functions deploy whatsapp-agent
supabase functions deploy demo-callback
supabase functions deploy inbox-send
```

## Orden recomendado para un cambio full-stack

1. **Backend primero** (migración + edge functions): suele ser retrocompatible
   (p. ej. columnas nuevas al final de un RETURNS TABLE → el frontend viejo las ignora).
2. **Frontend después** por Git: commit → push → PR → merge a `main`.

Así el sistema nunca queda en un estado roto entre ambos deploys.
