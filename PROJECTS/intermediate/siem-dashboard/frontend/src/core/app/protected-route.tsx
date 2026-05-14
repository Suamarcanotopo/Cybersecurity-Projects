// ===================
// ©AngelaMos | 2026
// protected-route.tsx
//
// Route guard that redirects unauthenticated users to the login page
//
// Reads isAuthenticated from the auth store. If the user is not logged in,
// navigates to /login and preserves the attempted path in location state so
// login can redirect back after a successful login.
//
// Key components:
//   ProtectedRoute - renders Outlet when authenticated, redirects otherwise
//
// Connects to:
//   router.tsx - wraps all authenticated routes
//   auth.store.ts - reads isAuthenticated
// ===================

import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { ROUTES } from '@/config'
import { useAuthStore } from '@/core/stores'

export function ProtectedRoute(): React.ReactElement {
  const location = useLocation()
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)

  if (!isAuthenticated) {
    return (
      <Navigate
        to={ROUTES.LOGIN}
        state={{ from: location.pathname + location.search }}
        replace
      />
    )
  }

  return <Outlet />
}
