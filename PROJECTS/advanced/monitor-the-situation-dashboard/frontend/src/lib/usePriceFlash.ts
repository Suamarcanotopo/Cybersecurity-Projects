// ©AngelaMos | 2026
// usePriceFlash.ts

import { useEffect, useRef, useState } from 'react'

export type FlashDir = 'up' | 'down' | null

interface FlashState {
  dir: FlashDir
  key: number
}

const FLASH_MS = 600

export function usePriceFlash(price: number | null): FlashState {
  const prevRef = useRef<number | null>(null)
  const [state, setState] = useState<FlashState>({ dir: null, key: 0 })
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (price === null) return

    const prev = prevRef.current
    prevRef.current = price

    if (prev === null || price === prev) return

    if (timerRef.current !== null) clearTimeout(timerRef.current)

    const dir: FlashDir = price > prev ? 'up' : 'down'
    setState((s) => ({ dir, key: s.key + 1 }))

    timerRef.current = setTimeout(() => {
      setState((s) => ({ ...s, dir: null }))
    }, FLASH_MS)
  }, [price])

  useEffect(() => {
    return () => {
      if (timerRef.current !== null) clearTimeout(timerRef.current)
    }
  }, [])

  return state
}
