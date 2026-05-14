// ©AngelaMos | 2026
// routers.tsx

import { createBrowserRouter, type RouteObject } from 'react-router-dom'
import { UserRole } from '@/api/types'
import { ROUTES } from '@/config'
import { ProtectedRoute } from './protected-route'

const routes: RouteObject[] = [
  {
    path: ROUTES.HOME,
    lazy: () => import('@/pages/dashboard'),
  },
  {
    path: ROUTES.LOGIN,
    lazy: () => import('@/pages/login'),
  },
  {
    path: ROUTES.REGISTER,
    lazy: () => import('@/pages/register'),
  },
  {
    element: <ProtectedRoute />,
    children: [
      {
        path: ROUTES.SETTINGS,
        lazy: () => import('@/pages/settings'),
      },
    ],
  },
  {
    element: <ProtectedRoute allowedRoles={[UserRole.ADMIN]} />,
    children: [
      {
        path: ROUTES.ADMIN.USERS,
        lazy: () => import('@/pages/admin'),
      },
    ],
  },
  {
    path: '*',
    lazy: () => import('@/pages/dashboard'),
  },
]

export const router = createBrowserRouter(routes)
