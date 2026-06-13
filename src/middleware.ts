import { type NextRequest, NextResponse } from 'next/server';
import { createServerClient } from '@supabase/ssr';

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet: { name: string; value: string; options?: object }[]) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        }
      }
    }
  );

  const { data: { user } } = await supabase.auth.getUser();

  const pathname = request.nextUrl.pathname;
  const isAuthRoute = pathname.startsWith('/login') || pathname.startsWith('/auth');
  const isOnboarding = pathname.startsWith('/onboarding');
  const isPublic = isAuthRoute || pathname.startsWith('/_next');

  if (!user && !isPublic) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  // Usuario autenticado pero sin workspace (signup nuevo) → onboarding.
  // Con workspace, /onboarding no aplica → home.
  if (user && !isAuthRoute) {
    const { data: me } = await supabase
      .from('crm_users')
      .select('workspace_id')
      .eq('auth_user_id', user.id)
      .limit(1)
      .maybeSingle();

    if (!me?.workspace_id && !isOnboarding) {
      return NextResponse.redirect(new URL('/onboarding', request.url));
    }
    if (me?.workspace_id && isOnboarding) {
      return NextResponse.redirect(new URL('/', request.url));
    }
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)']
};
