// ===================
// © AngelaMos | 2026
// routers.tsx
//
// React Router browser router with Shell layout and lazy page routes
//
// All routes nest under the Shell layout element. Dashboard and Session
// pages are lazily imported so they split into separate chunks at build
// time.
//
// Connects to:
//   config.ts - reads ROUTES.DASHBOARD for the dashboard path
//   core/app/shell.tsx - Shell is the parent layout element
//   pages/dashboard/index.tsx - lazy-loaded for /
//   pages/session/index.tsx - lazy-loaded for /session/:id
// ===================

import { createBrowserRouter, type RouteObject } from 'react-router-dom'
import { ROUTES } from '@/config'
import { Shell } from './shell'

const routes: RouteObject[] = [
  {
    element: <Shell />,
    children: [
      {
        path: ROUTES.DASHBOARD,
        lazy: () => import('@/pages/dashboard'),
      },
      {
        path: '/session/:id',
        lazy: () => import('@/pages/session'),
      },
    ],
  },
]

export const router = createBrowserRouter(routes)
