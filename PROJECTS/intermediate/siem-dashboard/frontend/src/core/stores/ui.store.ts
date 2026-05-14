// ===================
// ©AngelaMos | 2026
// ui.store.ts
//
// Zustand store for sidebar UI state with partial localStorage persistence
//
// Manages sidebarOpen (mobile overlay) and sidebarCollapsed (desktop
// compressed mode) flags. Only sidebarCollapsed is persisted across reloads.
// Also exports two selector hooks for components that only need a single flag.
//
// Key exports:
//   useUIStore - main Zustand store hook
//   useSidebarOpen, useSidebarCollapsed - selector hooks
//
// Connects to:
//   shell.tsx - reads and mutates all sidebar state
// ===================

import { create } from 'zustand'
import { devtools, persist } from 'zustand/middleware'
import { STORAGE_KEYS } from '@/config'

interface UIState {
  sidebarOpen: boolean
  sidebarCollapsed: boolean
  toggleSidebar: () => void
  setSidebarOpen: (open: boolean) => void
  toggleSidebarCollapsed: () => void
}

export const useUIStore = create<UIState>()(
  devtools(
    persist(
      (set) => ({
        sidebarOpen: false,
        sidebarCollapsed: false,

        toggleSidebar: () =>
          set(
            (state) => ({ sidebarOpen: !state.sidebarOpen }),
            false,
            'ui/toggleSidebar'
          ),

        setSidebarOpen: (open) =>
          set({ sidebarOpen: open }, false, 'ui/setSidebarOpen'),

        toggleSidebarCollapsed: () =>
          set(
            (state) => ({
              sidebarCollapsed: !state.sidebarCollapsed,
            }),
            false,
            'ui/toggleSidebarCollapsed'
          ),
      }),
      {
        name: STORAGE_KEYS.UI,
        partialize: (state) => ({
          sidebarCollapsed: state.sidebarCollapsed,
        }),
      }
    ),
    { name: 'UIStore' }
  )
)

export const useSidebarOpen = (): boolean => useUIStore((s) => s.sidebarOpen)
export const useSidebarCollapsed = (): boolean =>
  useUIStore((s) => s.sidebarCollapsed)
