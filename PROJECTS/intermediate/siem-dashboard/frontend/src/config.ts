// ===================
// ©AngelaMos | 2026
// constants.ts
//
// Application-wide constants for the SIEM dashboard frontend
//
// Centralizes all API endpoint paths, React Query cache keys, client-side
// route paths, localStorage keys, cache timing config, HTTP status codes,
// pagination defaults, and display label maps. Every hook and page imports
// from here instead of defining URLs inline.
//
// Key exports:
//   API_ENDPOINTS - all backend route paths, static and parameterized
//   QUERY_KEYS - structured cache key factories for React Query
//   ROUTES - client-side navigation path constants
//   QUERY_CONFIG - stale time, GC time, and retry settings
//   STORAGE_KEYS - localStorage key names for persisted stores
// ===================

const API_VERSION = 'v1'

export const API_ENDPOINTS = {
  AUTH: {
    REGISTER: `/${API_VERSION}/auth/register`,
    LOGIN: `/${API_VERSION}/auth/login`,
    ME: `/${API_VERSION}/auth/me`,
    UPDATE_PROFILE: `/${API_VERSION}/auth/me`,
  },
  ADMIN: {
    USERS: `/${API_VERSION}/admin/users`,
    USER_BY_ID: (id: string) => `/${API_VERSION}/admin/users/${id}`,
    USER_ROLE: (id: string) => `/${API_VERSION}/admin/users/${id}/role`,
    DEACTIVATE: (id: string) => `/${API_VERSION}/admin/users/${id}/deactivate`,
    ACTIVATE: (id: string) => `/${API_VERSION}/admin/users/${id}/activate`,
  },
  DASHBOARD: {
    OVERVIEW: `/${API_VERSION}/dashboard`,
    TIMELINE: `/${API_VERSION}/dashboard/timeline`,
    SEVERITY: `/${API_VERSION}/dashboard/severity-breakdown`,
    TOP_SOURCES: `/${API_VERSION}/dashboard/top-sources`,
  },
  LOGS: {
    LIST: `/${API_VERSION}/logs`,
    BY_ID: (id: string) => `/${API_VERSION}/logs/${id}`,
    INGEST: `/${API_VERSION}/logs/ingest`,
    SEARCH: `/${API_VERSION}/logs/search`,
    STREAM: `/${API_VERSION}/logs/stream`,
    PIVOT: `/${API_VERSION}/logs/pivot`,
  },
  ALERTS: {
    LIST: `/${API_VERSION}/alerts`,
    BY_ID: (id: string) => `/${API_VERSION}/alerts/${id}`,
    STATUS: (id: string) => `/${API_VERSION}/alerts/${id}/status`,
    STREAM: `/${API_VERSION}/alerts/stream`,
  },
  RULES: {
    LIST: `/${API_VERSION}/rules`,
    CREATE: `/${API_VERSION}/rules`,
    BY_ID: (id: string) => `/${API_VERSION}/rules/${id}`,
    UPDATE: (id: string) => `/${API_VERSION}/rules/${id}`,
    DELETE: (id: string) => `/${API_VERSION}/rules/${id}`,
    TEST: (id: string) => `/${API_VERSION}/rules/${id}/test`,
  },
  SCENARIOS: {
    AVAILABLE: `/${API_VERSION}/scenarios/available`,
    RUNNING: `/${API_VERSION}/scenarios/running`,
    START: `/${API_VERSION}/scenarios/start`,
    STOP: (runId: string) => `/${API_VERSION}/scenarios/${runId}/stop`,
    PAUSE: (runId: string) => `/${API_VERSION}/scenarios/${runId}/pause`,
    RESUME: (runId: string) => `/${API_VERSION}/scenarios/${runId}/resume`,
    SPEED: (runId: string) => `/${API_VERSION}/scenarios/${runId}/speed`,
  },
} as const

export const QUERY_KEYS = {
  AUTH: {
    ALL: ['auth'] as const,
    ME: () => [...QUERY_KEYS.AUTH.ALL, 'me'] as const,
  },
  DASHBOARD: {
    ALL: ['dashboard'] as const,
    OVERVIEW: () => [...QUERY_KEYS.DASHBOARD.ALL, 'overview'] as const,
    TIMELINE: (hours: number, bucket: number) =>
      [...QUERY_KEYS.DASHBOARD.ALL, 'timeline', { hours, bucket }] as const,
    SEVERITY: () => [...QUERY_KEYS.DASHBOARD.ALL, 'severity'] as const,
    TOP_SOURCES: (limit: number) =>
      [...QUERY_KEYS.DASHBOARD.ALL, 'top-sources', { limit }] as const,
  },
  LOGS: {
    ALL: ['logs'] as const,
    LIST: (page: number, size: number) =>
      [...QUERY_KEYS.LOGS.ALL, 'list', { page, size }] as const,
    BY_ID: (id: string) => [...QUERY_KEYS.LOGS.ALL, 'detail', id] as const,
    SEARCH: (query: string, page: number, size: number) =>
      [...QUERY_KEYS.LOGS.ALL, 'search', { query, page, size }] as const,
    PIVOT: (params: { ip?: string; username?: string; hostname?: string }) =>
      [...QUERY_KEYS.LOGS.ALL, 'pivot', params] as const,
  },
  ALERTS: {
    ALL: ['alerts'] as const,
    LIST: (page: number, size: number) =>
      [...QUERY_KEYS.ALERTS.ALL, 'list', { page, size }] as const,
    BY_ID: (id: string) => [...QUERY_KEYS.ALERTS.ALL, 'detail', id] as const,
  },
  RULES: {
    ALL: ['rules'] as const,
    LIST: () => [...QUERY_KEYS.RULES.ALL, 'list'] as const,
    BY_ID: (id: string) => [...QUERY_KEYS.RULES.ALL, 'detail', id] as const,
  },
  SCENARIOS: {
    ALL: ['scenarios'] as const,
    AVAILABLE: () => [...QUERY_KEYS.SCENARIOS.ALL, 'available'] as const,
    RUNNING: () => [...QUERY_KEYS.SCENARIOS.ALL, 'running'] as const,
  },
  ADMIN: {
    ALL: ['admin'] as const,
    USERS: (page: number, size: number) =>
      [...QUERY_KEYS.ADMIN.ALL, 'users', { page, size }] as const,
    USER_BY_ID: (id: string) => [...QUERY_KEYS.ADMIN.ALL, 'user', id] as const,
  },
} as const

export const ROUTES = {
  LANDING: '/',
  LOGIN: '/login',
  REGISTER: '/register',
  DASHBOARD: '/dashboard',
  LOGS: '/logs',
  ALERTS: '/alerts',
  RULES: '/rules',
  SCENARIOS: '/scenarios',
  SETTINGS: '/settings',
  ADMIN_USERS: '/admin/users',
} as const

export const STORAGE_KEYS = {
  AUTH: 'siem-auth',
  UI: 'siem-ui',
} as const

export const QUERY_CONFIG = {
  STALE_TIME: {
    USER: 0,
    STATIC: Infinity,
    FREQUENT: 1000 * 10,
    DASHBOARD: 1000 * 15,
  },
  GC_TIME: {
    DEFAULT: 1000 * 60 * 30,
    LONG: 1000 * 60 * 60,
  },
  RETRY: {
    DEFAULT: 3,
    NONE: 0,
  },
} as const

export const HTTP_STATUS = {
  OK: 200,
  CREATED: 201,
  NO_CONTENT: 204,
  BAD_REQUEST: 400,
  UNAUTHORIZED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  UNPROCESSABLE: 422,
  TOO_MANY_REQUESTS: 429,
  INTERNAL_SERVER: 500,
} as const

export const PAGINATION = {
  DEFAULT_PAGE: 1,
  DEFAULT_SIZE: 25,
  MAX_SIZE: 100,
} as const

export const SEVERITY_LABELS: Record<string, string> = {
  critical: 'Critical',
  high: 'High',
  medium: 'Medium',
  low: 'Low',
  info: 'Info',
}

export const ALERT_STATUS_LABELS: Record<string, string> = {
  new: 'New',
  acknowledged: 'Acknowledged',
  investigating: 'Investigating',
  resolved: 'Resolved',
  false_positive: 'False Positive',
}

export const SCENARIO_STATUS_LABELS: Record<string, string> = {
  running: 'Running',
  completed: 'Completed',
  stopped: 'Stopped',
  paused: 'Paused',
  error: 'Error',
}

export type ApiEndpoint = typeof API_ENDPOINTS
export type QueryKey = typeof QUERY_KEYS
export type Route = typeof ROUTES
