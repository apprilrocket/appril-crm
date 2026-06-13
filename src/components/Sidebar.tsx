'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { LayoutDashboard, Users, Kanban, Send, Megaphone, Workflow, FileText, Settings, LogOut, MessageCircle, BarChart3, ListChecks, ShieldCheck } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useRouter } from 'next/navigation';
import { cn } from '@/lib/utils';
import { useEffect, useState } from 'react';

const nav = [
  { href: '/',           label: 'Inicio',          icon: LayoutDashboard },
  { href: '/inbox',      label: 'Inbox',           icon: MessageCircle },
  { href: '/leads',      label: 'Leads',           icon: Users },
  { href: '/lists',      label: 'Listas',          icon: ListChecks },
  { href: '/pipeline',   label: 'Pipeline',        icon: Kanban },
  { href: '/send',       label: 'Envío manual',    icon: Send },
  { href: '/campaigns',  label: 'Campañas',        icon: Megaphone },
  { href: '/automations',label: 'Automatizaciones',icon: Workflow },
  { href: '/reports',    label: 'Reportes',        icon: BarChart3 },
  { href: '/quality',    label: 'Calidad de datos',icon: ShieldCheck },
  { href: '/templates',  label: 'Templates',       icon: FileText },
  { href: '/settings',   label: 'Settings',        icon: Settings }
];

export function Sidebar({
  userEmail,
  workspaceName,
  workspaceSlug
}: {
  userEmail?: string;
  workspaceName?: string;
  workspaceSlug?: string;
}) {
  const pathname = usePathname();
  const router = useRouter();
  const [unread, setUnread] = useState(0);

  // Refresca el contador de no leídos al navegar
  useEffect(() => {
    const supabase = createClient();
    supabase.rpc('inbox_unread_count').then(({ data }) => setUnread(data ?? 0));
  }, [pathname]);

  async function signOut() {
    const supabase = createClient();
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  return (
    <aside className="w-56 shrink-0 border-r border-neutral-200 bg-white flex flex-col h-screen sticky top-0">
      <div className="px-4 py-5 border-b border-neutral-100">
        <div className="font-semibold text-neutral-900">{workspaceName ?? 'CRM'}</div>
        <div className="text-xs text-neutral-500 mt-0.5">workspace: {workspaceSlug ?? '—'}</div>
      </div>

      <nav className="flex-1 px-2 py-3 space-y-0.5">
        {nav.map(item => {
          const active = pathname === item.href || (item.href !== '/' && pathname.startsWith(item.href));
          const Icon = item.icon;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                'flex items-center gap-2 px-3 py-2 text-sm rounded-md transition-colors',
                active
                  ? 'bg-brand-50 text-brand-700 font-medium'
                  : 'text-neutral-600 hover:bg-neutral-50 hover:text-neutral-900'
              )}
            >
              <Icon size={16} />
              {item.label}
              {item.href === '/inbox' && unread > 0 && (
                <span className="ml-auto text-[10px] font-semibold bg-brand-600 text-white rounded-full px-1.5 py-0.5 min-w-[18px] text-center">
                  {unread}
                </span>
              )}
            </Link>
          );
        })}
      </nav>

      <div className="border-t border-neutral-100 p-3">
        <div className="text-xs text-neutral-500 truncate mb-2">{userEmail}</div>
        <button
          onClick={signOut}
          className="flex items-center gap-2 px-2 py-1.5 text-xs text-neutral-600 hover:text-neutral-900 w-full"
        >
          <LogOut size={14} /> Cerrar sesión
        </button>
      </div>
    </aside>
  );
}
