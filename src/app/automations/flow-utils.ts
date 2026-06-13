// Tipos y validación del grafo de automatización — compartido entre builder (client) y actions (server)

export type FlowNode = {
  id: string;
  type: string;
  position: { x: number; y: number };
  data: Record<string, any>;
};
export type FlowEdge = {
  id: string;
  source: string;
  target: string;
  sourceHandle?: string | null;
  targetHandle?: string | null;
};
export type Flow = { nodes: FlowNode[]; edges: FlowEdge[] };

export function validateFlow(flow: Flow): string[] {
  const errors: string[] = [];
  const triggers = flow.nodes.filter(n => n.type === 'trigger');
  if (triggers.length !== 1) errors.push('El flujo debe tener exactamente un disparador.');

  for (const n of flow.nodes) {
    const out = flow.edges.filter(e => e.source === n.id);
    if ((n.type === 'send_email' || n.type === 'send_whatsapp') && !n.data?.templateKey) {
      errors.push(`Un nodo de ${n.type === 'send_email' ? 'email' : 'WhatsApp'} no tiene template asignado.`);
    }
    if (n.type === 'condition') {
      if (!n.data?.kind) errors.push('Una condición no tiene criterio configurado.');
      if (!out.some(e => e.sourceHandle === 'yes') && !out.some(e => e.sourceHandle === 'no')) {
        errors.push('Una condición no tiene ramas conectadas (Sí/No).');
      }
    }
    if (n.type === 'goal' && !n.data?.kind) errors.push('La meta no tiene criterio de conversión configurado.');
    if (n.type === 'trigger' && out.length === 0 && flow.nodes.length > 1) {
      errors.push('El disparador no está conectado a ningún paso.');
    }
  }
  return errors;
}
