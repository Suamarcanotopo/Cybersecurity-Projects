// ===================
// © AngelaMos | 2025
// protected-route.tsx
// ===================

import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { useCurrentUser } from '@/api/hooks'
import type { UserRole } from '@/api/types'
import { ROUTES } from '@/config'
import { useAuthStore } from '@/core/lib'

interface ProtectedRouteProps {
  allowedRoles?: UserRole[]
  redirectTo?: string
}

export function ProtectedRoute({
  allowedRoles,
  redirectTo = ROUTES.LOGIN,
}: ProtectedRouteProps): React.ReactElement {
  const location = useLocation()
  const { isAuthenticated, isLoading, user } = useAuthStore()

  // On cold load, isAuthenticated is restored from localStorage but the
  // access token is gone (not persisted). useCurrentUser fires /auth/me;
  // the axios interceptor catches the inevitable 401 and refreshes via
  // the HttpOnly cookie. While that's in flight we hold the route — no
  // flash of protected content before bouncing to /login.
  const { isLoading: hydrating, isError: hydrationFailed } = useCurrentUser()

  if (isLoading || (isAuthenticated && hydrating && user === null)) {
    return <div>Loading…</div>
  }

  if (!isAuthenticated || hydrationFailed) {
    return (
      <Navigate
        to={redirectTo}
        state={{ from: location.pathname + location.search }}
        replace
      />
    )
  }

  if (
    allowedRoles !== undefined &&
    allowedRoles.length > 0 &&
    user !== null &&
    !allowedRoles.includes(user.role)
  ) {
    return <Navigate to={ROUTES.UNAUTHORIZED} replace />
  }

  return <Outlet />
}
