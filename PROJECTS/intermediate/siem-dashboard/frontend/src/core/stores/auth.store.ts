// ===================
// ©AngelaMos | 2026
// auth.store.ts
//
// Zustand store for authentication state with localStorage persistence
//
// Holds the authenticated user, JWT access token, and isAuthenticated flag.
// Persisted to localStorage under the siem-auth key so sessions survive page
// reloads. Also exports three fine-grained selector hooks for components that
// only need a single slice of state.
//
// Key exports:
//   useAuthStore - main Zustand store hook with login, logout, updateUser actions
//   useUser, useIsAuthenticated, useAccessToken - selector hooks
//   AuthUser - interface for the stored user object
//
// Connects to:
//   api.ts - reads accessToken and calls logout()
//   useAuth.ts - calls login, logout, setAccessToken, updateUser
//   protected-route.tsx, admin-route.tsx, shell.tsx - read auth state
// ===================

import { create } from 'zustand'
import { devtools, persist } from 'zustand/middleware'
import { STORAGE_KEYS } from '@/config'

export interface AuthUser {
  id: string
  username: string
  email: string
  role: string
  is_active: boolean
}

interface AuthState {
  user: AuthUser | null
  accessToken: string | null
  isAuthenticated: boolean
}

interface AuthActions {
  login: (user: AuthUser, accessToken: string) => void
  logout: () => void
  setAccessToken: (token: string | null) => void
  updateUser: (updates: Partial<AuthUser>) => void
}

type AuthStore = AuthState & AuthActions

export const useAuthStore = create<AuthStore>()(
  devtools(
    persist(
      (set) => ({
        user: null,
        accessToken: null,
        isAuthenticated: false,

        login: (user, accessToken) =>
          set({ user, accessToken, isAuthenticated: true }, false, 'auth/login'),

        logout: () =>
          set(
            { user: null, accessToken: null, isAuthenticated: false },
            false,
            'auth/logout'
          ),

        setAccessToken: (token) =>
          set({ accessToken: token }, false, 'auth/setAccessToken'),

        updateUser: (updates) =>
          set(
            (state) => ({
              user: state.user !== null ? { ...state.user, ...updates } : null,
            }),
            false,
            'auth/updateUser'
          ),
      }),
      {
        name: STORAGE_KEYS.AUTH,
        partialize: (state) => ({
          user: state.user,
          accessToken: state.accessToken,
          isAuthenticated: state.isAuthenticated,
        }),
      }
    ),
    { name: 'AuthStore' }
  )
)

export const useUser = (): AuthUser | null => useAuthStore((s) => s.user)
export const useIsAuthenticated = (): boolean =>
  useAuthStore((s) => s.isAuthenticated)
export const useAccessToken = (): string | null =>
  useAuthStore((s) => s.accessToken)
