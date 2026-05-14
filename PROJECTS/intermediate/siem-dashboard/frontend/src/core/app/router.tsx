// ===================
// ©AngelaMos | 2026
// router.tsx
//
// Browser router definition with lazy-loaded routes and auth guards
//
// Public routes (landing, login, register) load without authentication. All
// other routes nest under ProtectedRoute and the Shell layout. Admin routes
// are further nested under AdminRoute. All page components are lazy-loaded
// via dynamic import to enable code splitting.
//
// Key exports:
//   router - the createBrowserRouter instance mounted in App.tsx
//
// Connects to:
//   protected-route.tsx, admin-route.tsx, shell.tsx - layout route elements
//   config.ts - ROUTES path constants
// ===================

import { createBrowserRouter, type RouteObject } from 'react-router-dom'
import { ROUTES } from '@/config'
import { AdminRoute } from './admin-route'
import { ProtectedRoute } from './protected-route'
import { Shell } from './shell'

const routes: RouteObject[] = [
  {
    path: ROUTES.LANDING,
    lazy: () => import('@/routes/landing'),
  },
  {
    path: ROUTES.LOGIN,
    lazy: () => import('@/routes/login'),
  },
  {
    path: ROUTES.REGISTER,
    lazy: () => import('@/routes/register'),
  },
  {
    element: <ProtectedRoute />,
    children: [
      {
        element: <Shell />,
        children: [
          {
            path: ROUTES.DASHBOARD,
            lazy: () => import('@/routes/dashboard'),
          },
          {
            path: ROUTES.LOGS,
            lazy: () => import('@/routes/logs'),
          },
          {
            path: ROUTES.ALERTS,
            lazy: () => import('@/routes/alerts'),
          },
          {
            path: ROUTES.RULES,
            lazy: () => import('@/routes/rules'),
          },
          {
            path: ROUTES.SCENARIOS,
            lazy: () => import('@/routes/scenarios'),
          },
          {
            path: ROUTES.SETTINGS,
            lazy: () => import('@/routes/settings'),
          },
          {
            element: <AdminRoute />,
            children: [
              {
                path: ROUTES.ADMIN_USERS,
                lazy: () => import('@/routes/admin'),
              },
            ],
          },
        ],
      },
    ],
  },
  {
    path: '*',
    lazy: () => import('@/routes/landing'),
  },
]

export const router = createBrowserRouter(routes)
