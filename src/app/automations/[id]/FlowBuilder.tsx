'use client';

import { useCallback, useMemo, useState, useRef } from 'react';
import {
  ReactFlow,
  ReactFlowProvider,
  Background,
  Controls,
  MiniMap,
  addEdge,
  useNodesState,
  useEdgesState,
  useReactFlow,
  MarkerType,
  type Node,
  type Edge,
  type Connection,
  type NodeTypes
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import {
  ArrowLeft, Save, Play, Pause, Zap, Mail, MessageCircle, Clock,
  GitBranch, Trophy, LogOut, Trash2, Users, CheckCircle2, AlertTriangle
} from 'lucide-react';
import { saveAutomation, setAutomationStatus, enrollSegment } from '../actions';
import { validateFlow, type Flow } from '../flow-utils';
import { TriggerNode, EmailNode, WhatsappNode, WaitNode, ConditionNode, GoalNode, ExitNode } from './FlowNodes';

type Template = { template_key: string; name: string; channel: string };
type Stage = { key: string; label: string };
type Stats = { active: number; converted: number; completed: number; failed: number };

const SEGMENTS = ['SUPER_HOT', 'HOT', 'WARM', 'COLD'];

const PALETTE = [
  { type: 'send_email', label: 'Enviar email', icon: Mail, color: 'text-sky-600' },
  { type: 'send_whatsapp', label: 'Enviar WhatsApp', icon: MessageCircle, color: 'text-emerald-600' },
  { type: 'wait', label: 'Esperar', icon: Clock, color: 'text-amber-600' },
  { type: 'condition', label: 'Condición Sí/No', icon: GitBranch, color: 'text-violet-600' },
  { type: 'goal', label: 'Meta / Conversión', icon: Trophy, color: 'text-yellow-600' },
  { type: 'exit', label: 'Salida', icon: LogOut, color: 'text-neutral-500' }
] as const;

const DEFAULT_DATA: Record<string, Record<string, any>> = {
  send_email: {},
  send_whatsapp: {},
  wait: { amount: 1, unit: 'days' },
  condition: { kind: 'email_opened' },
  goal: { kind: 'stage_is', value: 'converted', recheckHours: 6, timeoutDays: 30 },
  exit: {}
};

const nodeTypes: NodeTypes = {
  trigger: TriggerNode,
  send_email: EmailNode,
  send_whatsapp: WhatsappNode,
  wait: WaitNode,
  condition: ConditionNode,
  goal: GoalNode,
  exit: ExitNode
};

export function FlowBuilder(props: {
  automation: { id: string; name: string; status: string; flow: Flow };
  templates: Template[];
  stages: Stage[];
  stats: Stats;
}) {
  return (
    <ReactFlowProvider>
      <Builder {...props} />
    </ReactFlowProvider>
  );
}

function Builder({ automation, templates, stages, stats }: {
  automation: { id: string; name: string; status: string; flow: Flow };
  templates: Template[];
  stages: Stage[];
  stats: Stats;
}) {
  const router = useRouter();
  const { screenToFlowPosition } = useReactFlow();
  const wrapperRef = useRef<HTMLDivElement>(null);

  const [nodes, setNodes, onNodesChange] = useNodesState(
    (automation.flow.nodes ?? []).map(n => ({ ...n, data: n.data ?? {} })) as Node[]
  );
  const [edges, setEdges, onEdgesChange] = useEdgesState(
    (automation.flow.edges ?? []).map(e => decorateEdge(e as Edge))
  );
  const [name, setName] = useState(automation.name);
  const [status, setStatus] = useState(automation.status);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [messages, setMessages] = useState<{ kind: 'ok' | 'error'; text: string }[]>([]);
  const [enrollSeg, setEnrollSeg] = useState('HOT');
  const idCounter = useRef(1);

  const selectedNode = nodes.find(n => n.id === selectedId) ?? null;

  const onConnect = useCallback((conn: Connection) => {
    setEdges(eds =>
      addEdge(
        decorateEdge({ ...conn, id: `e-${conn.source}-${conn.sourceHandle ?? 'out'}-${conn.target}` } as Edge),
        // una sola arista por handle de salida: reemplaza la existente
        eds.filter(e => !(e.source === conn.source && (e.sourceHandle ?? null) === (conn.sourceHandle ?? null)))
      )
    );
  }, [setEdges]);

  const addNodeAt = useCallback((type: string, position: { x: number; y: number }) => {
    const id = `${type}-${Date.now().toString(36)}-${idCounter.current++}`;
    setNodes(ns => [...ns, { id, type, position, data: { ...DEFAULT_DATA[type] } }]);
    setSelectedId(id);
  }, [setNodes]);

  const onPaletteClick = (type: string) => {
    const bounds = wrapperRef.current?.getBoundingClientRect();
    const center = screenToFlowPosition({
      x: (bounds?.left ?? 0) + (bounds?.width ?? 800) / 2 + (Math.random() * 60 - 30),
      y: (bounds?.top ?? 0) + (bounds?.height ?? 600) / 2 + (Math.random() * 60 - 30)
    });
    addNodeAt(type, center);
  };

  const onDrop = useCallback((event: React.DragEvent) => {
    event.preventDefault();
    const type = event.dataTransfer.getData('application/crm-node');
    if (!type) return;
    addNodeAt(type, screenToFlowPosition({ x: event.clientX, y: event.clientY }));
  }, [addNodeAt, screenToFlowPosition]);

  const updateSelectedData = (patch: Record<string, any>) => {
    if (!selectedId) return;
    setNodes(ns => ns.map(n => (n.id === selectedId ? { ...n, data: { ...n.data, ...patch } } : n)));
  };

  const deleteSelected = () => {
    if (!selectedId || selectedNode?.type === 'trigger') return;
    setNodes(ns => ns.filter(n => n.id !== selectedId));
    setEdges(es => es.filter(e => e.source !== selectedId && e.target !== selectedId));
    setSelectedId(null);
  };

  const serialize = (): Flow => ({
    nodes: nodes.map(n => ({ id: n.id, type: n.type!, position: n.position, data: n.data as any })),
    edges: edges.map(e => ({
      id: e.id, source: e.source, target: e.target, sourceHandle: e.sourceHandle ?? null
    }))
  });

  async function handleSave(): Promise<boolean> {
    setBusy(true);
    setMessages([]);
    const res = await saveAutomation(automation.id, { name, flow: serialize() });
    setBusy(false);
    if (res.errors) {
      setMessages(res.errors.map(text => ({ kind: 'error' as const, text })));
      return false;
    }
    setMessages([{ kind: 'ok', text: 'Flujo guardado.' }]);
    return true;
  }

  async function handleToggleStatus() {
    const target = status === 'active' ? 'paused' : 'active';
    if (target === 'active') {
      const errors = validateFlow(serialize());
      if (errors.length) { setMessages(errors.map(text => ({ kind: 'error' as const, text }))); return; }
      if (!(await handleSave())) return;
    }
    setBusy(true);
    const res = await setAutomationStatus(automation.id, target);
    setBusy(false);
    if (res.errors) { setMessages(res.errors.map(text => ({ kind: 'error' as const, text }))); return; }
    setStatus(target);
    setMessages([{ kind: 'ok', text: target === 'active' ? '🚀 Automatización activa. Los leads inscritos empiezan a avanzar en el próximo minuto.' : 'Automatización pausada.' }]);
    router.refresh();
  }

  async function handleEnroll() {
    setBusy(true);
    const res = await enrollSegment(automation.id, enrollSeg);
    setBusy(false);
    setMessages([
      res.error
        ? { kind: 'error', text: res.error }
        : { kind: 'ok', text: `${res.enrolled} leads del segmento ${enrollSeg} inscritos.` }
    ]);
    router.refresh();
  }

  const validationErrors = useMemo(() => validateFlow(serialize()), [nodes, edges]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="h-screen flex flex-col">
      {/* Header */}
      <div className="border-b border-neutral-200 bg-white px-5 py-3 flex items-center gap-3">
        <Link href="/automations" className="text-neutral-500 hover:text-neutral-900"><ArrowLeft size={18} /></Link>
        <input
          value={name}
          onChange={e => setName(e.target.value)}
          className="text-lg font-semibold text-neutral-900 bg-transparent border-b border-transparent hover:border-neutral-200 focus:border-brand-500 focus:outline-none px-1"
        />
        <span className={`px-2 py-0.5 rounded text-xs font-medium ${
          status === 'active' ? 'bg-emerald-100 text-emerald-800' :
          status === 'paused' ? 'bg-amber-100 text-amber-800' : 'bg-neutral-100 text-neutral-600'
        }`}>
          {status === 'active' ? 'Activa' : status === 'paused' ? 'Pausada' : 'Borrador'}
        </span>

        <div className="flex items-center gap-3 text-xs text-neutral-600 ml-4">
          <span className="inline-flex items-center gap-1"><Zap size={13} className="text-blue-500" />{stats.active} en curso</span>
          <span className="inline-flex items-center gap-1"><Trophy size={13} className="text-amber-500" />{stats.converted} convertidos</span>
          <span className="inline-flex items-center gap-1"><CheckCircle2 size={13} className="text-neutral-400" />{stats.completed} finalizados</span>
        </div>

        <div className="ml-auto flex items-center gap-2">
          <button
            onClick={handleSave}
            disabled={busy}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm border border-neutral-200 hover:bg-neutral-50 rounded-md disabled:opacity-50"
          >
            <Save size={14} /> Guardar
          </button>
          <button
            onClick={handleToggleStatus}
            disabled={busy}
            className={`inline-flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-white rounded-md disabled:opacity-50 ${
              status === 'active' ? 'bg-amber-600 hover:bg-amber-700' : 'bg-emerald-600 hover:bg-emerald-700'
            }`}
          >
            {status === 'active' ? <><Pause size={14} /> Pausar</> : <><Play size={14} /> Activar</>}
          </button>
        </div>
      </div>

      {/* Mensajes */}
      {messages.length > 0 && (
        <div className="px-5 py-2 space-y-1 bg-white border-b border-neutral-100">
          {messages.map((m, i) => (
            <div key={i} className={`text-xs flex items-center gap-1.5 ${m.kind === 'error' ? 'text-red-600' : 'text-emerald-700'}`}>
              {m.kind === 'error' ? <AlertTriangle size={12} /> : <CheckCircle2 size={12} />} {m.text}
            </div>
          ))}
        </div>
      )}

      <div className="flex-1 flex min-h-0">
        {/* Paleta */}
        <aside className="w-52 border-r border-neutral-200 bg-white p-3 space-y-1.5 overflow-y-auto">
          <div className="text-[11px] font-semibold uppercase text-neutral-400 px-1 mb-2">Elementos</div>
          {PALETTE.map(p => {
            const Icon = p.icon;
            return (
              <button
                key={p.type}
                draggable
                onDragStart={e => e.dataTransfer.setData('application/crm-node', p.type)}
                onClick={() => onPaletteClick(p.type)}
                className="w-full flex items-center gap-2 px-2.5 py-2 text-sm text-neutral-700 border border-neutral-200 rounded-md hover:border-brand-300 hover:bg-brand-50/50 cursor-grab active:cursor-grabbing"
              >
                <Icon size={15} className={p.color} /> {p.label}
              </button>
            );
          })}
          <p className="text-[11px] text-neutral-400 px-1 pt-2 leading-relaxed">
            Click o arrastra al lienzo. Conecta los elementos arrastrando desde el punto inferior
            de un nodo al superior del siguiente.
          </p>

          {/* Inscribir leads */}
          <div className="pt-3 mt-3 border-t border-neutral-100">
            <div className="text-[11px] font-semibold uppercase text-neutral-400 px-1 mb-2 flex items-center gap-1">
              <Users size={11} /> Inscribir leads
            </div>
            <select
              value={enrollSeg}
              onChange={e => setEnrollSeg(e.target.value)}
              className="w-full px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white mb-1.5"
            >
              {SEGMENTS.map(s => <option key={s} value={s}>{s}</option>)}
            </select>
            <button
              onClick={handleEnroll}
              disabled={busy || status !== 'active'}
              className="w-full px-2 py-1.5 text-sm bg-brand-600 hover:bg-brand-700 disabled:opacity-40 text-white rounded-md"
            >
              Inscribir segmento
            </button>
            {status !== 'active' && (
              <p className="text-[11px] text-neutral-400 mt-1 px-1">Activa la automatización primero.</p>
            )}
          </div>

          {validationErrors.length > 0 && (
            <div className="pt-3 mt-3 border-t border-neutral-100">
              <div className="text-[11px] font-semibold uppercase text-amber-600 px-1 mb-1">Por resolver</div>
              {validationErrors.map((e, i) => (
                <div key={i} className="text-[11px] text-amber-700 px-1 py-0.5">• {e}</div>
              ))}
            </div>
          )}
        </aside>

        {/* Lienzo */}
        <div ref={wrapperRef} className="flex-1" onDrop={onDrop} onDragOver={e => { e.preventDefault(); e.dataTransfer.dropEffect = 'move'; }}>
          <ReactFlow
            nodes={nodes}
            edges={edges}
            nodeTypes={nodeTypes}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onConnect={onConnect}
            onNodeClick={(_, n) => setSelectedId(n.id)}
            onPaneClick={() => setSelectedId(null)}
            deleteKeyCode={['Backspace', 'Delete']}
            onBeforeDelete={async ({ nodes: del }) => !del.some(n => n.type === 'trigger')}
            fitView
            proOptions={{ hideAttribution: true }}
            defaultEdgeOptions={{
              type: 'smoothstep',
              markerEnd: { type: MarkerType.ArrowClosed, width: 18, height: 18 }
            }}
          >
            <Background gap={18} size={1.2} />
            <Controls position="bottom-left" />
            <MiniMap pannable zoomable className="!bg-neutral-50" />
          </ReactFlow>
        </div>

        {/* Panel de configuración */}
        {selectedNode && (
          <aside className="w-72 border-l border-neutral-200 bg-white p-4 overflow-y-auto">
            <NodeConfigPanel
              node={selectedNode}
              templates={templates}
              stages={stages}
              onChange={updateSelectedData}
              onDelete={deleteSelected}
            />
          </aside>
        )}
      </div>
    </div>
  );
}

// Aristas Sí/No con etiqueta y color
function decorateEdge(e: Edge): Edge {
  const label = e.sourceHandle === 'yes' ? 'Sí' : e.sourceHandle === 'no' ? 'No' : undefined;
  return {
    ...e,
    type: 'smoothstep',
    label,
    labelStyle: { fontSize: 11, fontWeight: 600, fill: e.sourceHandle === 'yes' ? '#059669' : '#dc2626' },
    style: e.sourceHandle === 'yes' ? { stroke: '#10b981' } : e.sourceHandle === 'no' ? { stroke: '#f87171' } : undefined,
    markerEnd: { type: MarkerType.ArrowClosed, width: 18, height: 18 }
  };
}

// ------------------------------------------------------------------
// Panel de configuración por tipo de nodo
// ------------------------------------------------------------------
const CONDITION_KINDS: [string, string][] = [
  ['email_opened', 'Abrió un email'],
  ['email_clicked', 'Hizo click en un email'],
  ['wa_replied', 'Respondió por WhatsApp'],
  ['any_reply', 'Respondió por cualquier canal'],
  ['stage_is', 'Está en etapa…'],
  ['segment_is', 'Está en segmento…'],
  ['heat_gte', 'Heat score ≥ …'],
  ['event_occurred', 'Ocurrió el evento…']
];

function NodeConfigPanel({ node, templates, stages, onChange, onDelete }: {
  node: Node;
  templates: Template[];
  stages: Stage[];
  onChange: (patch: Record<string, any>) => void;
  onDelete: () => void;
}) {
  const d = (node.data ?? {}) as Record<string, any>;
  const emailTpls = templates.filter(t => t.channel === 'email');
  const waTpls = templates.filter(t => t.channel === 'whatsapp');

  return (
    <div className="space-y-4">
      <div className="text-sm font-semibold text-neutral-900">{nodeTitle(node.type!)}</div>

      {node.type === 'trigger' && (
        <>
          <Field label="¿Cómo entran los leads?">
            <select value={d.triggerType ?? 'manual'} onChange={e => onChange({ triggerType: e.target.value })} className={inputCls}>
              <option value="manual">Inscripción manual (botón)</option>
              <option value="segment_match">Por segmento (inscribir con botón)</option>
              <option value="event">Cuando ocurre un evento</option>
              <option value="stage">Cuando llega a una etapa</option>
            </select>
          </Field>
          {d.triggerType === 'event' && (
            <Field label="Tipo de evento" hint="ej: lead_created, wa_reply, cta_clicked">
              <input value={d.eventType ?? ''} onChange={e => onChange({ eventType: e.target.value })} className={inputCls} placeholder="lead_created" />
            </Field>
          )}
          {d.triggerType === 'stage' && (
            <Field label="Etapa que dispara">
              <select value={d.stage ?? ''} onChange={e => onChange({ stage: e.target.value })} className={inputCls}>
                <option value="">— elegir —</option>
                {stages.map(s => <option key={s.key} value={s.key}>{s.label}</option>)}
              </select>
            </Field>
          )}
          {d.triggerType === 'segment_match' && (
            <Field label="Segmento objetivo">
              <select value={d.segment ?? ''} onChange={e => onChange({ segment: e.target.value })} className={inputCls}>
                <option value="">— elegir —</option>
                {SEGMENTS.map(s => <option key={s} value={s}>{s}</option>)}
              </select>
            </Field>
          )}
          <label className="flex items-center gap-2 text-xs text-neutral-600">
            <input type="checkbox" checked={!!d.allowReenroll} onChange={e => onChange({ allowReenroll: e.target.checked })} />
            Permitir re-inscripción de leads que ya pasaron por el flujo
          </label>
        </>
      )}

      {node.type === 'send_email' && (
        <Field label="Template de email">
          <select value={d.templateKey ?? ''} onChange={e => onChange({ templateKey: e.target.value })} className={inputCls}>
            <option value="">— elegir template —</option>
            {emailTpls.map(t => <option key={t.template_key} value={t.template_key}>{t.name}</option>)}
          </select>
          {emailTpls.length === 0 && <p className="text-xs text-amber-600 mt-1">No hay templates de email activos. Crea uno en /templates.</p>}
        </Field>
      )}

      {node.type === 'send_whatsapp' && (
        <Field label="Template de WhatsApp">
          <select value={d.templateKey ?? ''} onChange={e => onChange({ templateKey: e.target.value })} className={inputCls}>
            <option value="">— elegir template —</option>
            {waTpls.map(t => <option key={t.template_key} value={t.template_key}>{t.name}</option>)}
          </select>
          {waTpls.length === 0 && <p className="text-xs text-amber-600 mt-1">No hay templates de WhatsApp activos (deben estar aprobados en Meta).</p>}
        </Field>
      )}

      {node.type === 'wait' && (
        <div className="flex gap-2">
          <Field label="Cantidad">
            <input type="number" min={1} value={d.amount ?? 1} onChange={e => onChange({ amount: parseInt(e.target.value) || 1 })} className={inputCls} />
          </Field>
          <Field label="Unidad">
            <select value={d.unit ?? 'days'} onChange={e => onChange({ unit: e.target.value })} className={inputCls}>
              <option value="minutes">minutos</option>
              <option value="hours">horas</option>
              <option value="days">días</option>
            </select>
          </Field>
        </div>
      )}

      {(node.type === 'condition' || node.type === 'goal') && (
        <>
          <Field label={node.type === 'goal' ? 'El lead convierte cuando…' : 'Evaluar si el lead…'}>
            <select value={d.kind ?? ''} onChange={e => onChange({ kind: e.target.value })} className={inputCls}>
              {CONDITION_KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </Field>
          {d.kind === 'stage_is' && (
            <Field label="Etapa">
              <select value={d.value ?? ''} onChange={e => onChange({ value: e.target.value })} className={inputCls}>
                <option value="">— elegir —</option>
                {stages.map(s => <option key={s.key} value={s.key}>{s.label}</option>)}
              </select>
            </Field>
          )}
          {d.kind === 'segment_is' && (
            <Field label="Segmento">
              <select value={d.value ?? ''} onChange={e => onChange({ value: e.target.value })} className={inputCls}>
                <option value="">— elegir —</option>
                {SEGMENTS.map(s => <option key={s} value={s}>{s}</option>)}
              </select>
            </Field>
          )}
          {d.kind === 'heat_gte' && (
            <Field label="Score mínimo">
              <input type="number" min={1} value={d.value ?? 10} onChange={e => onChange({ value: e.target.value })} className={inputCls} />
            </Field>
          )}
          {d.kind === 'event_occurred' && (
            <Field label="Tipo de evento" hint="ej: demo_created, contact_submitted">
              <input value={d.value ?? ''} onChange={e => onChange({ value: e.target.value })} className={inputCls} />
            </Field>
          )}
          {node.type === 'goal' && (
            <>
              <div className="flex gap-2">
                <Field label="Re-chequear cada (h)">
                  <input type="number" min={1} value={d.recheckHours ?? 6} onChange={e => onChange({ recheckHours: parseInt(e.target.value) || 6 })} className={inputCls} />
                </Field>
                <Field label="Plazo máx (días)">
                  <input type="number" min={1} value={d.timeoutDays ?? 30} onChange={e => onChange({ timeoutDays: parseInt(e.target.value) || 30 })} className={inputCls} />
                </Field>
              </div>
              <p className="text-[11px] text-neutral-500 leading-relaxed">
                Si se cumple la meta, el run termina como <strong>convertido</strong> 🏆.
                Si vence el plazo, sigue por la rama <strong>No</strong> (o termina si no hay rama).
              </p>
            </>
          )}
          {node.type === 'condition' && (
            <p className="text-[11px] text-neutral-500 leading-relaxed">
              Conecta la salida <strong className="text-emerald-700">Sí</strong> (izquierda) y
              la salida <strong className="text-red-600">No</strong> (derecha) a los siguientes pasos.
            </p>
          )}
        </>
      )}

      {node.type === 'exit' && (
        <p className="text-xs text-neutral-500">El lead sale del flujo y el run se marca como finalizado.</p>
      )}

      {node.type !== 'trigger' && (
        <button
          onClick={onDelete}
          className="w-full inline-flex items-center justify-center gap-1.5 px-3 py-1.5 text-xs text-red-600 border border-red-200 hover:bg-red-50 rounded-md"
        >
          <Trash2 size={12} /> Eliminar elemento
        </button>
      )}
    </div>
  );
}

function nodeTitle(type: string) {
  return ({
    trigger: '⚡ Disparador',
    send_email: '✉️ Enviar email',
    send_whatsapp: '💬 Enviar WhatsApp',
    wait: '⏱ Esperar',
    condition: '🔀 Condición',
    goal: '🏆 Meta / Conversión',
    exit: '🚪 Salida'
  } as Record<string, string>)[type] ?? type;
}

const inputCls = 'w-full px-2 py-1.5 text-sm border border-neutral-200 rounded-md bg-white';

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <label className="block flex-1">
      <span className="text-xs font-medium text-neutral-600">{label}</span>
      <div className="mt-1">{children}</div>
      {hint && <p className="text-[11px] text-neutral-400 mt-0.5">{hint}</p>}
    </label>
  );
}
