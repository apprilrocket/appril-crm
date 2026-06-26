#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { buildServer } from "./server.js";

async function main() {
  const server = buildServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stderr para no contaminar el canal stdio del protocolo
  console.error("appril-mcp-campaigns listo (stdio).");
}

main().catch((e) => {
  console.error("Fallo al iniciar el MCP:", e);
  process.exit(1);
});
