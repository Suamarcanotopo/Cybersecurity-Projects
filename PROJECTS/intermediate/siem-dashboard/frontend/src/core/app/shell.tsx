// ===================
// ©AngelaMos | 2026
// shell.tsx
//
// Authenticated application shell with sidebar navigation and page layout
//
// Renders the collapsible sidebar with nav links, an admin-conditional users
// link, and a logout button. Wraps the main content in an ErrorBoundary and
// Suspense so lazy-loaded routes load cleanly. Sidebar open state is managed
// via UIStore; collapse preference persists across reloads.
//
// Key components:
//   Shell - the outer layout component used inside ProtectedRoute
//
// Connects to:
//   router.tsx - Shell is mounted as a layout route element
//   auth.store.ts - reads user and role for admin nav and avatar letter
//   ui.store.ts - manages sidebar open/collapsed state
//   useAuth.ts - calls useLogout for the logout button
// ===================

import { Suspense } from 'react'
import { ErrorBoundary, type FallbackProps } from 'react-error-boundary'
import { GiButterflyWarning } from 'react-icons/gi'
import {
  LuActivity,
  LuChevronLeft,
  LuChevronRight,
  LuLayoutDashboard,
  LuLogOut,
  LuMenu,
  LuPlay,
  LuScroll,
  LuSettings,
  LuShield,
  LuUsers,
} from 'react-icons/lu'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useLogout } from '@/api/hooks'
import { ROUTES } from '@/config'
import { useAuthStore, useUIStore } from '@/core/stores'
import styles from './shell.module.scss'

const NAV_ITEMS = [
  { path: ROUTES.DASHBOARD, label: 'Dashboard', icon: LuLayoutDashboard },
  { path: ROUTES.LOGS, label: 'Log Viewer', icon: LuScroll },
  { path: ROUTES.ALERTS, label: 'Alerts', icon: GiButterflyWarning },
  { path: ROUTES.RULES, label: 'Rules', icon: LuShield },
  { path: ROUTES.SCENARIOS, label: 'Scenarios', icon: LuPlay },
] as const

const BOTTOM_NAV_ITEMS = [
  { path: ROUTES.SETTINGS, label: 'Settings', icon: LuSettings },
] as const

const ADMIN_NAV_ITEMS = [
  { path: ROUTES.ADMIN_USERS, label: 'Users', icon: LuUsers },
] as const

function ShellErrorFallback({ error }: FallbackProps): React.ReactElement {
  const message = error instanceof Error ? error.message : String(error)
  return (
    <div className={styles.error}>
      <h2>Something went wrong</h2>
      <pre>{message}</pre>
    </div>
  )
}

function ShellLoading(): React.ReactElement {
  return <div className={styles.loading}>Loading...</div>
}

function getPageTitle(pathname: string): string {
  const all = [...NAV_ITEMS, ...BOTTOM_NAV_ITEMS, ...ADMIN_NAV_ITEMS]
  const item = all.find((i) => i.path === pathname)
  return item?.label ?? 'Dashboard'
}

export function Shell(): React.ReactElement {
  const location = useLocation()
  const { sidebarOpen, sidebarCollapsed, toggleSidebar, toggleSidebarCollapsed } =
    useUIStore()
  const { mutate: logout } = useLogout()
  const user = useAuthStore((s) => s.user)
  const isAdmin = user?.role === 'admin'

  const pageTitle = getPageTitle(location.pathname)
  const avatarLetter = user?.username?.[0]?.toUpperCase() ?? 'U'

  return (
    <div className={styles.shell}>
      <aside
        className={`${styles.sidebar} ${sidebarOpen ? styles.open : ''} ${sidebarCollapsed ? styles.collapsed : ''}`}
      >
        <div className={styles.sidebarHeader}>
          <div className={styles.logoGroup}>
            <LuActivity className={styles.logoIcon} />
            <span className={styles.logo}>SIEM</span>
          </div>
          <button
            type="button"
            className={styles.collapseBtn}
            onClick={toggleSidebarCollapsed}
            aria-label={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            {sidebarCollapsed ? <LuChevronRight /> : <LuChevronLeft />}
          </button>
        </div>

        <nav className={styles.nav}>
          {NAV_ITEMS.map((item) => (
            <NavLink
              key={item.path}
              to={item.path}
              className={({ isActive }) =>
                `${styles.navItem} ${isActive ? styles.active : ''}`
              }
              onClick={() => sidebarOpen && toggleSidebar()}
            >
              <item.icon className={styles.navIcon} />
              <span className={styles.navLabel}>{item.label}</span>
            </NavLink>
          ))}

          {isAdmin && (
            <>
              <div className={styles.navDivider} />
              {ADMIN_NAV_ITEMS.map((item) => (
                <NavLink
                  key={item.path}
                  to={item.path}
                  className={({ isActive }) =>
                    `${styles.navItem} ${isActive ? styles.active : ''}`
                  }
                  onClick={() => sidebarOpen && toggleSidebar()}
                >
                  <item.icon className={styles.navIcon} />
                  <span className={styles.navLabel}>{item.label}</span>
                </NavLink>
              ))}
            </>
          )}
        </nav>

        <div className={styles.sidebarFooter}>
          {BOTTOM_NAV_ITEMS.map((item) => (
            <NavLink
              key={item.path}
              to={item.path}
              className={({ isActive }) =>
                `${styles.navItem} ${isActive ? styles.active : ''}`
              }
              onClick={() => sidebarOpen && toggleSidebar()}
            >
              <item.icon className={styles.navIcon} />
              <span className={styles.navLabel}>{item.label}</span>
            </NavLink>
          ))}
          <button
            type="button"
            className={styles.logoutBtn}
            onClick={() => logout()}
          >
            <LuLogOut className={styles.logoutIcon} />
            <span className={styles.logoutText}>Logout</span>
          </button>
        </div>
      </aside>

      {sidebarOpen && (
        <button
          type="button"
          className={styles.overlay}
          onClick={toggleSidebar}
          onKeyDown={(e) => e.key === 'Escape' && toggleSidebar()}
          aria-label="Close sidebar"
        />
      )}

      <div
        className={`${styles.main} ${sidebarCollapsed ? styles.collapsed : ''}`}
      >
        <header className={styles.header}>
          <div className={styles.headerLeft}>
            <button
              type="button"
              className={styles.menuBtn}
              onClick={toggleSidebar}
              aria-label="Toggle menu"
            >
              <LuMenu />
            </button>
            <h1 className={styles.pageTitle}>{pageTitle}</h1>
          </div>

          <div className={styles.headerRight}>
            <span className={styles.avatar}>{avatarLetter}</span>
          </div>
        </header>

        <main className={styles.content}>
          <ErrorBoundary FallbackComponent={ShellErrorFallback}>
            <Suspense fallback={<ShellLoading />}>
              <Outlet />
            </Suspense>
          </ErrorBoundary>
        </main>
      </div>
    </div>
  )
}
