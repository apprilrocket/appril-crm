import type { Metadata } from 'next';
import './globals.css';
import { Sidebar } from '@/components/Sidebar';
import { createClient } from '@/lib/supabase/server';

export const metadata: Metadata = {
  title: 'CRM',
  description: 'CRM multicanal con automatización'
};

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  // Workspace del usuario — RLS solo deja ver el propio.
  let workspace: { name: string; slug: string } | null = null;
  if (user) {
    const { data } = await supabase.from('workspaces').select('name, slug').limit(1).maybeSingle();
    workspace = data;
  }

  return (
    <html lang="es">
      <body className="antialiased min-h-screen">
        {user && workspace ? (
          <div className="flex">
            <Sidebar userEmail={user.email} workspaceName={workspace.name} workspaceSlug={workspace.slug} />
            {/* min-w-0: sin esto, el main no puede encogerse y el contenido ancho desborda a la derecha */}
          <main className="flex-1 min-w-0 min-h-screen">{children}</main>
          </div>
        ) : (
          <main>{children}</main>
        )}
      </body>
    </html>
  );
}
