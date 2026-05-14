// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Admin-only user management table with role, status, and delete controls
//
// Renders a paginated table of all users. Each row is a UserRow component
// that checks whether the row belongs to the current user and disables
// self-modification actions. Role changes fire immediately via a select
// element. Activate/deactivate toggle based on is_active. Delete is permanent.
// UserRow is an internal helper component.
//
// Key components:
//   Component - lazy-loaded admin users page; displayName "Admin Users"
//
// Connects to:
//   useAdmin.ts - user list, role update, activate, deactivate, delete mutations
//   auth.store.ts - reads current user ID for self-protection logic
//   admin.types.ts - UserResponse, UserRole types
// ===================

import { useState } from 'react'
import {
  LuBan,
  LuChevronLeft,
  LuChevronRight,
  LuCircleCheck,
  LuTrash2,
} from 'react-icons/lu'
import {
  useAdminActivateUser,
  useAdminDeactivateUser,
  useAdminDeleteUser,
  useAdminUpdateRole,
  useAdminUsers,
} from '@/api/hooks'
import type { UserResponse, UserRole } from '@/api/types'
import { PAGINATION } from '@/config'
import { useAuthStore } from '@/core/stores'
import styles from './admin.module.scss'

export function Component(): React.ReactElement {
  const [page, setPage] = useState<number>(PAGINATION.DEFAULT_PAGE)
  const { data, isLoading } = useAdminUsers({
    page,
    per_page: PAGINATION.DEFAULT_SIZE,
  })

  return (
    <div className={styles.page}>
      <div className={styles.toolbar}>
        <span className={styles.count}>{data?.total ?? 0} users</span>
      </div>

      <table className={styles.table}>
        <thead>
          <tr>
            <th className={styles.th}>Username</th>
            <th className={styles.th}>Email</th>
            <th className={styles.th}>Role</th>
            <th className={styles.th}>Status</th>
            <th className={styles.th}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {isLoading
            ? Array.from({ length: 5 }, (_, i) => (
                <tr key={`skel-${i}`}>
                  <td className={styles.skeleton} colSpan={5} />
                </tr>
              ))
            : data?.items.map((user) => <UserRow key={user.id} user={user} />)}
          {!isLoading && data?.items.length === 0 && (
            <tr>
              <td className={styles.empty} colSpan={5}>
                No users found
              </td>
            </tr>
          )}
        </tbody>
      </table>

      {data !== undefined && data.pages > 1 && (
        <div className={styles.pagination}>
          <button
            type="button"
            className={styles.pageBtn}
            disabled={page <= 1}
            onClick={() => setPage((p) => p - 1)}
          >
            <LuChevronLeft />
          </button>
          <span className={styles.pageInfo}>
            {page} / {data.pages}
          </span>
          <button
            type="button"
            className={styles.pageBtn}
            disabled={page >= data.pages}
            onClick={() => setPage((p) => p + 1)}
          >
            <LuChevronRight />
          </button>
        </div>
      )}
    </div>
  )
}

Component.displayName = 'Admin Users'

function UserRow({ user }: { user: UserResponse }): React.ReactElement {
  const currentUser = useAuthStore((s) => s.user)
  const isSelf = currentUser?.id === user.id

  const updateRole = useAdminUpdateRole()
  const deactivate = useAdminDeactivateUser()
  const activate = useAdminActivateUser()
  const deleteUser = useAdminDeleteUser()

  const handleRoleChange = (role: string): void => {
    updateRole.mutate({ userId: user.id, payload: { role: role as UserRole } })
  }

  return (
    <tr>
      <td className={styles.td}>{user.username}</td>
      <td className={styles.td}>{user.email}</td>
      <td className={styles.td}>
        <select
          className={styles.roleSelect}
          value={user.role}
          disabled={isSelf || updateRole.isPending}
          onChange={(e) => handleRoleChange(e.target.value)}
        >
          <option value="analyst">Analyst</option>
          <option value="admin">Admin</option>
        </select>
      </td>
      <td className={styles.td}>
        <span
          className={`${styles.statusDot} ${user.is_active ? styles.active : ''}`}
        />
      </td>
      <td className={styles.td}>
        <div className={styles.actions}>
          {user.is_active ? (
            <button
              type="button"
              className={styles.actionBtn}
              disabled={isSelf || deactivate.isPending}
              onClick={() => deactivate.mutate(user.id)}
              aria-label="Deactivate user"
            >
              <LuBan />
            </button>
          ) : (
            <button
              type="button"
              className={styles.actionBtn}
              disabled={activate.isPending}
              onClick={() => activate.mutate(user.id)}
              aria-label="Activate user"
            >
              <LuCircleCheck />
            </button>
          )}
          <button
            type="button"
            className={`${styles.actionBtn} ${styles.dangerBtn}`}
            disabled={isSelf || deleteUser.isPending}
            onClick={() => deleteUser.mutate(user.id)}
            aria-label="Delete user"
          >
            <LuTrash2 />
          </button>
        </div>
      </td>
    </tr>
  )
}
