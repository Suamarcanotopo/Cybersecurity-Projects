// ©AngelaMos | 2026
// presentationMode.ts

import { useEffect } from 'react'
import { STORAGE_KEYS } from '@/config'
import { useUIStore } from '@/stores/ui'

function readInitial(): boolean {
  return localStorage.getItem(STORAGE_KEYS.PRESENTATION_MODE) === '1'
}

function persist(on: boolean): void {
  if (on) {
    localStorage.setItem(STORAGE_KEYS.PRESENTATION_MODE, '1')
  } else {
    localStorage.removeItem(STORAGE_KEYS.PRESENTATION_MODE)
  }
}

function isTypingInForm(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  if (target.isContentEditable) return true
  return (
    target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement
  )
}

export const presentationMode = {
  readInitial,
  useGlobalShortcut(): void {
    const setMode = useUIStore((s) => s.setPresentationMode)

    useEffect(() => {
      setMode(readInitial())

      function onKey(e: KeyboardEvent): void {
        if (e.key === 'f' || e.key === 'F') {
          if (isTypingInForm(e.target)) return
          const next = !useUIStore.getState().presentationMode
          setMode(next)
          persist(next)
        } else if (e.key === 'Escape') {
          setMode(false)
          persist(false)
        }
      }

      document.addEventListener('keydown', onKey)
      return () => document.removeEventListener('keydown', onKey)
    }, [setMode])
  },
}
