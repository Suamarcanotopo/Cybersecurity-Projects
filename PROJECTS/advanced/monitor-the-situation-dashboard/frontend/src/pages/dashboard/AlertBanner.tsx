// ©AngelaMos | 2026
// AlertBanner.tsx

import { useEffect } from 'react'
import { FiX } from 'react-icons/fi'
import { useUIStore } from '@/stores/ui'
import styles from './AlertBanner.module.scss'

const AUTO_DISMISS_MS = 30_000

export function AlertBanner(): React.ReactElement | null {
  const alert = useUIStore((s) => s.currentAlert)
  const dismiss = useUIStore((s) => s.dismissAlert)

  useEffect(() => {
    if (!alert) return
    const id = setTimeout(dismiss, AUTO_DISMISS_MS)
    return () => clearTimeout(id)
  }, [alert, dismiss])

  if (!alert) return null

  return (
    <aside className={styles.banner} role="alert">
      <span className={styles.message}>{alert.message}</span>
      <button
        type="button"
        className={styles.dismiss}
        onClick={dismiss}
        aria-label="Dismiss"
      >
        <FiX aria-hidden />
      </button>
    </aside>
  )
}

AlertBanner.displayName = 'AlertBanner'
