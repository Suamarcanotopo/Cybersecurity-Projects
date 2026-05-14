// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Settings page showing current account info and a profile update form
//
// The top section displays the current username, email, and role read-only
// from the auth store. The form only submits when at least one field has a
// new value and current_password is provided. On success the form fields
// reset to empty so placeholders show the current values again.
//
// Key components:
//   Component - lazy-loaded settings page; displayName "Settings"
//
// Connects to:
//   useAuth.ts - useUpdateProfile mutation
//   auth.store.ts - reads current user for display and placeholder values
// ===================

import { useState } from 'react'
import { useUpdateProfile } from '@/api/hooks'
import { useAuthStore } from '@/core/stores'
import styles from './settings.module.scss'

export function Component(): React.ReactElement {
  const user = useAuthStore((s) => s.user)
  const updateProfile = useUpdateProfile()

  const [username, setUsername] = useState('')
  const [email, setEmail] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [currentPassword, setCurrentPassword] = useState('')

  const hasChanges =
    username.length > 0 || email.length > 0 || newPassword.length > 0

  const handleSubmit = (e: React.FormEvent): void => {
    e.preventDefault()
    if (!hasChanges || currentPassword.length === 0) return

    updateProfile.mutate(
      {
        current_password: currentPassword,
        ...(username.length > 0 ? { username } : {}),
        ...(email.length > 0 ? { email } : {}),
        ...(newPassword.length > 0 ? { password: newPassword } : {}),
      },
      {
        onSuccess: () => {
          setUsername('')
          setEmail('')
          setNewPassword('')
          setCurrentPassword('')
        },
      }
    )
  }

  const handleReset = (): void => {
    setUsername('')
    setEmail('')
    setNewPassword('')
    setCurrentPassword('')
  }

  return (
    <div className={styles.page}>
      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>Account</h2>
        <div className={styles.infoGrid}>
          <span className={styles.infoLabel}>Username</span>
          <span className={styles.infoValue}>{user?.username}</span>
          <span className={styles.infoLabel}>Email</span>
          <span className={styles.infoValue}>{user?.email}</span>
          <span className={styles.infoLabel}>Role</span>
          <span className={styles.roleBadge}>{user?.role}</span>
        </div>
      </div>

      <form className={styles.section} onSubmit={handleSubmit}>
        <h2 className={styles.sectionTitle}>Update Profile</h2>
        <div className={styles.form}>
          <div className={styles.field}>
            <label className={styles.label} htmlFor="settingsUsername">
              New Username
            </label>
            <input
              id="settingsUsername"
              className={styles.input}
              placeholder={user?.username}
              value={username}
              onChange={(e) => setUsername(e.target.value)}
            />
          </div>
          <div className={styles.field}>
            <label className={styles.label} htmlFor="settingsEmail">
              New Email
            </label>
            <input
              id="settingsEmail"
              type="email"
              className={styles.input}
              placeholder={user?.email}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </div>

          <div className={styles.divider} />

          <div className={styles.field}>
            <label className={styles.label} htmlFor="settingsNewPassword">
              New Password
            </label>
            <input
              id="settingsNewPassword"
              type="password"
              className={styles.input}
              placeholder="Leave blank to keep current"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
            />
          </div>

          <div className={styles.divider} />

          <div className={styles.field}>
            <label className={styles.label} htmlFor="settingsCurrentPassword">
              Current Password
            </label>
            <input
              id="settingsCurrentPassword"
              type="password"
              className={styles.input}
              placeholder="Required to save changes"
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
            />
          </div>

          <div className={styles.formActions}>
            <button
              type="button"
              className={styles.cancelBtn}
              onClick={handleReset}
            >
              Reset
            </button>
            <button
              type="submit"
              className={styles.submitBtn}
              disabled={
                !hasChanges ||
                currentPassword.length === 0 ||
                updateProfile.isPending
              }
            >
              {updateProfile.isPending ? 'Saving...' : 'Save Changes'}
            </button>
          </div>
        </div>
      </form>
    </div>
  )
}

Component.displayName = 'Settings'
