/**
 * Test de integración contra la BD viva del CRM.
 * Ejercita los tools vía sus funciones de lógica y LIMPIA lo que crea.
 * Uso: npm run test:integration   (requiere mcp/.env con service role)
 *
 * Flags:
 *   RUN_SEND_TEST=0  → omite el envío real de email de prueba.
 */
import "dotenv/config";
import { db, WORKSPACE_ID } from "../src/db.js";
import { listSegments } from "../src/lib/segments.js";
import { listLeadLists, createList, importContacts } from "../src/lib/leadsLists.js";
import { listTemplates, createEmailTemplate, updateEmailTemplate } from "../src/lib/templates.js";
import { previewAudience, createCampaign, getCampaign } from "../src/lib/campaigns.js";
import { listAutomations, createAutomation, updateAutomation } from "../src/lib/automations.js";
import { queueStatus } from "../src/lib/monitoring.js";
import { sendTest } from "../src/lib/test.js";

let pass = 0, fail = 0;
const cleanup: (() => Promise<void>)[] = [];

async function step(name: string, fn: () => Promise<unknown>) {
  try {
    const r = await fn();
    console.log(`✅ ${name}`);
    console.log("   ", JSON.stringify(r).slice(0, 240));
    pass++;
    return r as any;
  } catch (e) {
    console.log(`❌ ${name}: ${(e as Error).message}`);
    fail++;
    return null;
  }
}

async function main() {
  console.log(`\n— Integration test (workspace ${WORKSPACE_ID}) —\n`);

  await step("list_segments", () => listSegments());
  await step("list_lead_lists", () => listLeadLists());
  await step("list_templates(email)", () => listTemplates({ channel: "email" }));
  await step("list_automations", () => listAutomations());
  await step("queue_status", () => queueStatus());

  // Template de email: crear (draft) → activar → limpiar
  const tpl = await step("create_email_template (draft)", () =>
    createEmailTemplate({
      name: "MCP test " + Date.now(),
      subject: "Prueba {{full_name}}",
      html_body: "<p>Hola {{full_name}}, esto es una prueba del MCP.</p>",
    }));
  if (tpl?.template_key) {
    cleanup.push(async () => { await db.from("message_templates").delete().eq("workspace_id", WORKSPACE_ID).eq("template_key", tpl.template_key); });
    await step("update_email_template (activate)", () => updateEmailTemplate({ template_key: tpl.template_key, status: "active" }));
  }

  // Lista + import (usa un contacto basura que luego se borra)
  const junkEmail = `mcp_test_${Date.now()}@example.test`;
  const list = await step("create_list", () => createList({ name: "MCP test list " + Date.now() }));
  if (list?.id) cleanup.push(async () => { await db.from("lead_lists").delete().eq("workspace_id", WORKSPACE_ID).eq("id", list.id); });
  if (list?.name) {
    const imp = await step("import_contacts (1 nuevo)", () =>
      importContacts({ list_name: list.name, contacts: [{ full_name: "MCP Junk", email: junkEmail }] }));
    cleanup.push(async () => { await db.from("leads_master").delete().eq("workspace_id", WORKSPACE_ID).eq("email_normalized", junkEmail); });
    void imp;
  }

  // Automation: crear borrador + actualizar flow
  const auto = await step("create_automation", () => createAutomation({ name: "MCP test auto " + Date.now() }));
  if (auto?.id) {
    cleanup.push(async () => { await db.from("automations").delete().eq("workspace_id", WORKSPACE_ID).eq("id", auto.id); });
    await step("update_automation (flow)", () => updateAutomation({
      id: auto.id,
      flow: { nodes: [{ id: "trigger", type: "trigger", position: { x: 0, y: 0 }, data: { triggerType: "manual" } }], edges: [] },
    }));
  }

  // Preview + create campaign (requieren la migración crm_preview_audience)
  const prev = await step("preview_audience (email, SUPER_HOT)", () =>
    previewAudience({ channel: "email", segments: ["SUPER_HOT"] }));
  if (prev) {
    const camp = await step("create_campaign (draft, SUPER_HOT)", () =>
      createCampaign({ name: "MCP test campaign " + Date.now(), channel: "email", template_key: "demo_email_intro", segments: ["SUPER_HOT"] }));
    if (camp?.id) {
      cleanup.push(async () => { await db.from("campaigns").delete().eq("workspace_id", WORKSPACE_ID).eq("id", camp.id); });
      await step("get_campaign", () => getCampaign(camp.id));
    }
  } else {
    console.log("   (preview/create_campaign omitidos: ¿migración mcp_campaign_launch no aplicada?)");
  }

  // send_test real (a la allowlist)
  if (process.env.RUN_SEND_TEST !== "0") {
    await step("send_test → mauricio@todoc.co", () =>
      sendTest({ template_key: "demo_email_intro", to_address: "mauricio@todoc.co" }));
  }

  // Limpieza
  console.log("\n— Limpiando artefactos de prueba —");
  for (const c of cleanup.reverse()) { try { await c(); } catch (e) { console.log("  cleanup warn:", (e as Error).message); } }

  console.log(`\nResultado: ${pass} ok, ${fail} fallos.\n`);
  process.exit(fail > 0 ? 1 : 0);
}

main();
