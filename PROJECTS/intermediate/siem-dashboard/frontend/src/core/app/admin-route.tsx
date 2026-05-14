// ===================
// ©AngelaMos | 2026
// admin-route.tsx
//
// Route guard that restricts access to admin-only routes
//
// Checks the current user's role from the auth store. Non-admin users are
// silently redirected to the dashboard. Renders an Outlet for child routes
// when the admin role is confirmed.
//
// Key components:
//   AdminRoute - renders Outlet for admins, redirects others to dashboard
//
// Connects to:
//   router.tsx - wraps admin/users route
//   auth.store.ts - reads user.role
// ===================

import { Navigate, Outlet } from 'react-router-dom'
import { ROUTES } from '@/config'
import { useAuthStore } from '@/core/stores'

export function AdminRoute(): React.ReactElement {
  const user = useAuthStore((s) => s.user)

  if (user?.role !== 'admin') {
    return <Navigate to={ROUTES.DASHBOARD} replace />
  }

  return <Outlet />
}
