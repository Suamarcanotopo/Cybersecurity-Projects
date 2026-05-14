// ===================
// © AngelaMos | 2026
// config.ts
// ===================
const API_VERSION = 'v1'

export const API_ENDPOINTS = {
  AUTH: {
    LOGIN: `/${API_VERSION}/auth/login`,
    REGISTER: `/${API_VERSION}/auth/register`,
    REFRESH: `/${API_VERSION}/auth/refresh`,
    LOGOUT: `/${API_VERSION}/auth/logout`,
    LOGOUT_ALL: `/${API_VERSION}/auth/logout-all`,
    ME: `/${API_VERSION}/auth/me`,
    CHANGE_PASSWORD: `/${API_VERSION}/auth/change-password`,
  },
  USERS: {
    BASE: `/${API_VERSION}/users`,
    ME: `/${API_VERSION}/users/me`,
    EMAIL: `/${API_VERSION}/users/me/email`,
  },
  ADMIN: {
    USERS: {
      LIST: `/${API_VERSION}/admin/users`,
      CREATE: `/${API_VERSION}/admin/users`,
      BY_ID: (id: string) => `/${API_VERSION}/admin/users/${id}`,
      UPDATE: (id: string) => `/${API_VERSION}/admin/users/${id}`,
      DELETE: (id: string) => `/${API_VERSION}/admin/users/${id}`,
    },
  },
  NOTIFICATIONS: {
    CHANNELS: `/${API_VERSION}/notifications/channels`,
    CHANNEL_BY_ID: (id: string) => `/${API_VERSION}/notifications/channels/${id}`,
    CHANNEL_TEST: (id: string) =>
      `/${API_VERSION}/notifications/channels/${id}/test`,
    TELEGRAM: `/${API_VERSION}/notifications/telegram`,
    TELEGRAM_STATUS: `/${API_VERSION}/notifications/telegram/status`,
    TELEGRAM_TEST: `/${API_VERSION}/notifications/telegram/test`,
  },
  INTEL: {
    CVES: `/${API_VERSION}/intel/cves`,
    KEV: `/${API_VERSION}/intel/kev`,
    HIJACKS: `/${API_VERSION}/intel/hijacks`,
    OUTAGES: `/${API_VERSION}/intel/outages`,
    RANSOMWARE: `/${API_VERSION}/intel/ransomware`,
    QUAKES: `/${API_VERSION}/intel/quakes`,
  },
} as const

export const QUERY_KEYS = {
  AUTH: {
    ALL: ['auth'] as const,
    ME: () => [...QUERY_KEYS.AUTH.ALL, 'me'] as const,
  },
  USERS: {
    ALL: ['users'] as const,
    ME: () => [...QUERY_KEYS.USERS.ALL, 'me'] as const,
  },
  ADMIN: {
    ALL: ['admin'] as const,
    USERS: {
      ALL: () => [...QUERY_KEYS.ADMIN.ALL, 'users'] as const,
      LIST: (page: number, size: number) =>
        [...QUERY_KEYS.ADMIN.USERS.ALL(), 'list', { page, size }] as const,
      BY_ID: (id: string) =>
        [...QUERY_KEYS.ADMIN.USERS.ALL(), 'detail', id] as const,
    },
  },
  NOTIFICATIONS: {
    ALL: ['notifications'] as const,
    CHANNELS: () => [...QUERY_KEYS.NOTIFICATIONS.ALL, 'channels'] as const,
    TELEGRAM_STATUS: () =>
      [...QUERY_KEYS.NOTIFICATIONS.ALL, 'telegram-status'] as const,
  },
  INTEL: {
    ALL: ['intel'] as const,
    CVES: () => [...QUERY_KEYS.INTEL.ALL, 'cves'] as const,
    KEV: () => [...QUERY_KEYS.INTEL.ALL, 'kev'] as const,
    HIJACKS: () => [...QUERY_KEYS.INTEL.ALL, 'hijacks'] as const,
    OUTAGES: () => [...QUERY_KEYS.INTEL.ALL, 'outages'] as const,
    RANSOMWARE: () => [...QUERY_KEYS.INTEL.ALL, 'ransomware'] as const,
    QUAKES: () => [...QUERY_KEYS.INTEL.ALL, 'quakes'] as const,
  },
} as const

export const ROUTES = {
  HOME: '/',
  LOGIN: '/login',
  REGISTER: '/register',
  DASHBOARD: '/dashboard',
  SETTINGS: '/settings',
  UNAUTHORIZED: '/unauthorized',
  ADMIN: {
    DASHBOARD: '/admin',
    USERS: '/admin/users',
    USER_DETAIL: (id: string) => `/admin/users/${id}`,
  },
} as const

export const STORAGE_KEYS = {
  AUTH: 'auth-storage',
  UI: 'ui-storage',
  PRESENTATION_MODE: 'monitor:presentation-mode',
} as const

export const QUERY_CONFIG = {
  STALE_TIME: {
    USER: 1000 * 60 * 5,
    STATIC: Infinity,
    FREQUENT: 1000 * 30,
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
  TOO_MANY_REQUESTS: 429,
  INTERNAL_SERVER: 500,
} as const

export const PASSWORD_CONSTRAINTS = {
  MIN_LENGTH: 8,
  MAX_LENGTH: 128,
} as const

export const PAGINATION = {
  DEFAULT_PAGE: 1,
  DEFAULT_SIZE: 20,
  MAX_SIZE: 100,
} as const

export type ApiEndpoint = typeof API_ENDPOINTS
export type QueryKey = typeof QUERY_KEYS
export type Route = typeof ROUTES
