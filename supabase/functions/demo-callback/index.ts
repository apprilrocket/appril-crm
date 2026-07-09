// Appril CRM — Demo Callback
// Recibe POST de Appril cuando el doctor confirma/cancela la cita demo.
// Retoma la conversación de ventas desde el agente.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const WA_ACCESS_TOKEN = Deno.env.get("WA_ACCESS_TOKEN")!;
const WA_PHONE_ID     = Deno.env.get("WA_PHONE_NUMBER_ID")!;
const WA_API_VERSION  = Deno.env.get("WA_API_VERSION") ?? "v25.0";
const WORKSPACE_ID    = "e2096477-fa6a-4b8f-a8b3-bd46ad720167";

const SIGNUP_URL = "https://www.appril.co/empezar";
const DEMO_URL   = "https://cal.com/appril/15min";

// Auth del caller: appril-web (patient-confirmation-handler) manda
// x-callback-secret = SALES_DEMO_CALLBACK_SECRET. Mientras ENFORCE sea false
// solo se registra el resultado (log-only); al encender DEMO_CALLBACK_ENFORCE
// los callbacks sin secret válido se rechazan con 401.
const CALLBACK_SECRET = Deno.env.get("DEMO_CALLBACK_SECRET") ?? "";
const ENFORCE = (Deno.env.get("DEMO_CALLBACK_ENFORCE") ?? "false") === "true";

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const provided = req.headers.get("x-callback-secret") ?? "";
  const secretOk = CALLBACK_SECRET.length > 0 && timingSafeEqual(provided, CALLBACK_SECRET);
  if (!secretOk) {
    console.warn(
      `[demo-callback] secret ${provided ? "inválido" : "ausente"} (configurado=${CALLBACK_SECRET ? "sí" : "no"})` +
      (ENFORCE ? " — rechazado 401" : " — log-only, se procesa igual"),
    );
    if (ENFORCE) return new Response("Unauthorized", { status: 401 });
  }

  // Responder 200 rápido — procesar async
  const body = await req.json();
  processCallback(body).catch(console.error);
  return new Response("OK", { status: 200 });
});

async function processCallback(payload: any) {
  const { appointment_id, action, phone } = payload;
  if (!appointment_id || !action || !phone) return;

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // Buscar el lead por appointment_id guardado en lead_events.metadata
  const { data: demoEvent } = await sb
    .from("lead_events")
    .select("lead_id")
    .eq("event_type", "demo_created")
    .eq("metadata->>appointment_id", appointment_id)
    .maybeSingle();

  if (!demoEvent) return; // no es nuestro

  const leadId = demoEvent.lead_id;

  // Idempotencia: verificar si ya respondimos a este appointment_id
  const { data: already } = await sb
    .from("lead_events")
    .select("id")
    .eq("lead_id", leadId)
    .eq("event_type", "demo_callback_sent")
    .eq("metadata->>appointment_id", appointment_id)
    .maybeSingle();

  if (already) return; // ya respondimos, ignorar reenvíos

  // Construir mensaje según la acción del doctor
  let message: string;

  if (action === "confirm") {
    message =
      `Acaba de confirmar, doctor. 🎉\n\n` +
      `Eso que vivió — recibir el mensaje, ver los botones, confirmar con un toque — es exactamente lo que vivirían sus pacientes.\n\n` +
      `Sin llamadas. Sin perseguir a nadie. Sin WhatsApp manual.\n\n` +
      `Puede empezar hoy, sin tarjeta:\n${SIGNUP_URL}`;
  } else {
    message =
      `Canceló la cita demo, doctor — y eso también es parte de la experiencia.\n\n` +
      `En este momento su "paciente" ya recibió la notificación de cancelación. Automáticamente. Sin que nadie tuviera que escribirle.\n\n` +
      `Además su agenda quedó actualizada: usted o su asistente ya pueden citar a otro paciente. Es más, si tiene configurado el reagendamiento, Appril ayuda al propio paciente a buscar otro espacio dentro de su agenda.\n\n` +
      `Eso es lo que Appril hace por su consultorio todos los días.\n\n` +
      `Puede probar Appril gratis ahora mismo:\n${SIGNUP_URL}`;
  }

  // Enviar WA al doctor
  await sendWA(phone, message);

  // Registrar que ya respondimos (idempotencia futura)
  await sb.from("lead_events").insert({
    workspace_id: WORKSPACE_ID,
    lead_id: leadId,
    event_type: "demo_callback_sent",
    event_channel: "whatsapp",
    event_value: action,
    metadata: { appointment_id, action, phone },
  });

  // v3 — El remate forma parte de la conversación: guardarlo como wa_agent_reply
  // para que el agente IA lo vea en su historial (y el inbox lo muestre).
  await sb.from("lead_events").insert({
    workspace_id: WORKSPACE_ID,
    lead_id: leadId,
    event_type: "wa_agent_reply",
    event_channel: "whatsapp",
    event_value: message,
    metadata: { via: "demo_callback", appointment_id, action },
  });
}

async function sendWA(to: string, text: string) {
  const phone = to.replace(/^\+/, "");
  await fetch(`https://graph.facebook.com/${WA_API_VERSION}/${WA_PHONE_ID}/messages`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${WA_ACCESS_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to: phone,
      type: "text",
      text: { body: text },
    }),
  });
}
