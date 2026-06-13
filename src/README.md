# Appril CRM — Dashboard

Dashboard Next.js 14 (App Router) para el CRM de marketing de Appril. Lee y escribe directamente contra Supabase (`hwiocriejizjdqqcfrsj`).

## Stack

- Next.js 14 + App Router + Server Components
- Supabase JS + `@supabase/ssr` (SSR-friendly auth)
- Tailwind CSS
- TypeScript

## Setup (3 pasos)

### 1. Instalar dependencias

```bash
cd appril-crm
npm install
```

### 2. Variables de entorno

```bash
cp .env.local.example .env.local
```

Edita `.env.local` y agrega tu `SUPABASE_SERVICE_ROLE_KEY` desde:
https://supabase.com/dashboard/project/hwiocriejizjdqqcfrsj/settings/api

La `NEXT_PUBLIC_SUPABASE_URL` y la publishable key ya vienen configuradas para `hwiocriejizjdqqcfrsj`.

### 3. Crear tu usuario CRM en Supabase Auth

Como el dashboard usa Supabase Auth + magic link, necesitas que tu email exista en `auth.users` y que la fila `crm_users` lo apunte vía `auth_user_id`.

Hay dos formas:

**A. Vía dashboard de Supabase (más fácil):**
1. Ve a https://supabase.com/dashboard/project/hwiocriejizjdqqcfrsj/auth/users
2. Click "Invite user" → email `mauricio@todoc.co`
3. Revisa tu email, haz click en el magic link, te lleva a Supabase (lo cerramos)
4. Copia el `id` del usuario recién creado
5. Ejecuta en el SQL Editor:
```sql
UPDATE crm_users
SET auth_user_id = 'EL_UUID_DE_AUTH_USERS'
WHERE email = 'mauricio@todoc.co';
```

**B. Auto-magic (cuando levantes el dashboard):**
1. `npm run dev` y abre http://localhost:3000
2. En `/login` ingresa tu email — recibirás el magic link
3. Después del primer login, ejecuta el UPDATE de arriba con tu uuid (lo ves en `auth.users`)

### 4. Correr

```bash
npm run dev
```

Abre http://localhost:3000

## Estructura

```
app/
  layout.tsx              Layout raíz con Sidebar (solo si hay sesión)
  page.tsx                Home / KPIs
  login/page.tsx          Magic link login
  auth/callback/route.ts  OAuth callback de Supabase
  leads/
    page.tsx              Lista filtrable de leads
    [id]/page.tsx         Detalle del lead (timeline, notas, tareas)
    [id]/LeadActions.tsx  Componente cliente con acciones
  pipeline/page.tsx       Kanban por etapa
  send/
    page.tsx              Envío manual
    SendForm.tsx          Formulario cliente

components/
  Sidebar.tsx             Nav lateral
  SegmentBadge.tsx        Badges para segmentos y etapas

lib/
  supabase/client.ts      Cliente para Client Components
  supabase/server.ts      Cliente para Server Components
  supabase/admin.ts       Cliente service-role (server-only)
  utils.ts                Helpers (cn, formatDate, relativeTime)
```

## Páginas listas en el MVP

- ✅ `/` — KPIs + actividad reciente
- ✅ `/login` — Auth magic link
- ✅ `/leads` — Lista filtrable + búsqueda + paginación
- ✅ `/leads/[id]` — Detalle con timeline, notas, tareas, sequences
- ✅ `/pipeline` — Kanban view
- ✅ `/send` — Envío manual con búsqueda de lead

Páginas placeholder que vienen en Sprint 2/3:
- `/campaigns`, `/automations`, `/templates`, `/settings`

## Cómo se conecta con el Sender Lambda

El dashboard solo escribe en `message_queue` (status='pending'). El Sender Lambda corre cada N minutos, lee la cola, ejecuta los envíos (SES o WA Cloud API), y escribe en `message_attempts` + actualiza `message_queue.status`.

Cuando llegan webhooks de SES o WhatsApp (opens, clicks, replies, bounces), un Webhook Receiver Lambda los escribe como filas en `lead_events` y actualiza flags en `leads_master`.

Ver `../appril-sender/README.md` para el Sender.

## Deploy

Vercel free tier funciona perfecto:
```bash
npx vercel
```

Configura las mismas env vars en Vercel.

## TODO posteriores

- Generar `lib/database.types.ts` con `npm run types:generate` (requiere CLI de Supabase autenticada)
- Implementar `/campaigns` (CRUD + lanzar a segmento)
- Implementar `/templates` (editor email + WA con preview)
- Implementar `/automations` (builder visual de secuencias)
- Drag & drop real en Pipeline (con dnd-kit)
- Roles `viewer` con policies más finas en Supabase
