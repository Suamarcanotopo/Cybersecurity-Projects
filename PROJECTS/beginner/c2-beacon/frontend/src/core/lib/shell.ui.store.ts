// ===================
// © AngelaMos | 2026
// shell.ui.store.ts
//
// Zustand store for sidebar open and collapsed UI state
//
// Manages two boolean flags: sidebarOpen (transient, not persisted)
// and sidebarCollapsed (persisted to localStorage). Exposes toggle
// and setter actions alongside selector hooks for each flag.
//
// Key exports:
//   useUIStore - full Zustand store with sidebar state and actions
//   useSidebarOpen, useSidebarCollapsed - selector hooks
//
// Connects to:
//   config.ts - reads STORAGE_KEYS.UI for the localStorage key
//   core/app/shell.tsx - reads and mutates sidebar state
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
            (state) => ({ sidebarCollapsed: !state.sidebarCollapsed }),
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
