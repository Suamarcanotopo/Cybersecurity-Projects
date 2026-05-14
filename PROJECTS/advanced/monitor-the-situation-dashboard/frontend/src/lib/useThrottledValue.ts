// ©AngelaMos | 2026
// useThrottledValue.ts

import { useEffect, useRef, useState } from 'react'

const DEFAULT_INTERVAL_MS = 200

export function useThrottledValue<T>(
  value: T,
  intervalMs: number = DEFAULT_INTERVAL_MS
): T {
  const [throttled, setThrottled] = useState<T>(value)
  const latestRef = useRef<T>(value)
  const lastEmitRef = useRef<number>(0)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    latestRef.current = value
    const now = performance.now()
    const elapsed = now - lastEmitRef.current

    if (elapsed >= intervalMs) {
      lastEmitRef.current = now
      setThrottled(value)
      return
    }

    if (timerRef.current !== null) return
    timerRef.current = setTimeout(() => {
      timerRef.current = null
      lastEmitRef.current = performance.now()
      setThrottled(latestRef.current)
    }, intervalMs - elapsed)
  }, [value, intervalMs])

  useEffect(() => {
    return () => {
      if (timerRef.current !== null) clearTimeout(timerRef.current)
    }
  }, [])

  return throttled
}
