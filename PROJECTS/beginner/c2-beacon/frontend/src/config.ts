// ===================
// © AngelaMos | 2026
// config.ts
//
// Client-side URL constants for API endpoints, WebSocket paths, and routes
//
// All hard-coded paths live here so components never construct URLs
// directly. API_ENDPOINTS covers REST paths, WS_ENDPOINTS covers the
// operator WebSocket, ROUTES covers client-side navigation paths, and
// STORAGE_KEYS names the localStorage persistence key.
//
// Connects to:
//   core/ws.ts - reads WS_ENDPOINTS.OPERATOR
//   core/lib/shell.ui.store.ts - reads STORAGE_KEYS.UI
//   core/app/routers.tsx - reads ROUTES.DASHBOARD
//   core/app/shell.tsx - reads ROUTES.DASHBOARD
//   pages/dashboard/index.tsx - reads ROUTES.SESSION
//   pages/session/index.tsx - reads ROUTES.DASHBOARD
// ===================

export const API_BASE = '/api'

export const API_ENDPOINTS = {
  HEALTH: `${API_BASE}/health`,
  BEACONS: `${API_BASE}/beacons`,
  BEACON: (id: string) => `${API_BASE}/beacons/${id}`,
  BEACON_TASKS: (id: string) => `${API_BASE}/beacons/${id}/tasks`,
} as const

export const WS_ENDPOINTS = {
  OPERATOR: `${API_BASE}/ws/operator`,
} as const

export const ROUTES = {
  DASHBOARD: '/',
  SESSION: (id: string) => `/session/${id}`,
} as const

export const STORAGE_KEYS = {
  UI: 'c2-ui-storage',
} as const
