// Appril CRM — Demo Callback
// Recibe POST de Appril cuando el doctor confirma/cancela la cita demo.
// Retoma la conversación de ventas desde el agente.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const WA_ACCESS_TOKEN = Deno.env.get("WA_ACCESS_TOKEN")!;
const WA_PHONE_ID     = Deno.env.get("WA_PHONE_NUMBER_ID")!;
const WA_API_VERSION  = Deno.env.get("WA_API_VERSION") ?? "v25.0";
const WORKSPACE_ID    = "e2096477-fa6a-4b8f-a8b3-bd46ad720167";

const SIGNUP_URL = "https://app.appril.co/auth/sign-up";
const DEMO_URL   = "https://cal.com/appril/15min";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
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
      `Eso es lo que Appril hace por su consultorio todos los días.\n\n` +
      `¿Le comparto el link para empezar sin tarjeta?\n${SIGNUP_URL}`;
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
