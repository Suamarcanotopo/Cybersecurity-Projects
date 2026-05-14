// ©AngelaMos | 2026
// TopStrip.tsx

import { useEffect, useRef, useState } from 'react'
import {
  FiHelpCircle,
  FiMaximize2,
  FiMinimize2,
  FiSettings,
  FiUser,
  FiVolume2,
} from 'react-icons/fi'
import { useNavigate } from 'react-router-dom'
import { ROUTES } from '@/config'
import { useAuthStore } from '@/core/lib/auth.store'
import { useUIStore } from '@/stores/ui'
import styles from './TopStrip.module.scss'

const CIA_AUDIO_SRC = '/chip-in-my-brain.mp3'
const CIA_LABEL = 'IM BEING GANGSTALKED BY THE CIA'
const PWA_HINT_DURATION_MS = 4_000
const ABOUT_HOVER_DELAY_MS = 300

function isIOS(): boolean {
  return /iPad|iPhone|iPod/.test(navigator.userAgent)
}

function isInStandaloneMode(): boolean {
  return window.matchMedia('(display-mode: standalone)').matches
}

export function TopStrip(): React.ReactElement | null {
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const openAbout = useUIStore((s) => s.openAbout)
  const isPresentation = useUIStore((s) => s.presentationMode)
  const navigate = useNavigate()
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [showPWAHint, setShowPWAHint] = useState(false)
  const hintTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const aboutHoverRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    const handler = (): void => setIsFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', handler)
    return () => document.removeEventListener('fullscreenchange', handler)
  }, [])

  useEffect(() => {
    if (!showPWAHint) return
    const dismiss = (): void => {
      if (hintTimerRef.current) clearTimeout(hintTimerRef.current)
      setShowPWAHint(false)
    }
    document.addEventListener('pointerdown', dismiss, { capture: true })
    return () =>
      document.removeEventListener('pointerdown', dismiss, { capture: true })
  }, [showPWAHint])

  function handleCIA(): void {
    if (!audioRef.current) {
      audioRef.current = new Audio(CIA_AUDIO_SRC)
    }
    audioRef.current.currentTime = 0
    audioRef.current.play().catch(() => undefined)
  }

  function handleFullscreen(): void {
    if (isIOS() && !isInStandaloneMode()) {
      if (hintTimerRef.current) clearTimeout(hintTimerRef.current)
      setShowPWAHint(true)
      hintTimerRef.current = setTimeout(
        () => setShowPWAHint(false),
        PWA_HINT_DURATION_MS
      )
      return
    }
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => undefined)
    } else {
      document.documentElement.requestFullscreen().catch(() => undefined)
    }
  }

  if (isPresentation) return null

  return (
    <header className={styles.strip}>
      <div className={styles.left}>
        <span className={styles.title} title="I AM INSIDE THE WALLS (MONITORING)">
          MONITORING THE SITUATION
        </span>
        <button
          type="button"
          className={styles.iconButton}
          onClick={openAbout}
          onMouseEnter={() => {
            aboutHoverRef.current = setTimeout(openAbout, ABOUT_HOVER_DELAY_MS)
          }}
          onMouseLeave={() => {
            if (aboutHoverRef.current) clearTimeout(aboutHoverRef.current)
          }}
          aria-label="About"
        >
          <FiHelpCircle aria-hidden />
        </button>
      </div>

      <button
        type="button"
        className={styles.ciaButton}
        onClick={handleCIA}
        aria-label={CIA_LABEL}
      >
        <FiVolume2 className={styles.ciaIcon} aria-hidden />
        <span>{CIA_LABEL}</span>
      </button>

      <div className={styles.right}>
        <div className={styles.fullscreenWrap}>
          <button
            type="button"
            className={styles.iconButton}
            onClick={handleFullscreen}
            aria-label={isFullscreen ? 'Exit fullscreen' : 'Enter fullscreen'}
          >
            {isFullscreen ? (
              <FiMinimize2 aria-hidden />
            ) : (
              <FiMaximize2 aria-hidden />
            )}
          </button>
          {showPWAHint && (
            <div className={styles.pwaHint} role="tooltip">
              Tap <strong>Share</strong> → <strong>Add to Home Screen</strong> for
              fullscreen
            </div>
          )}
        </div>
        {isAuthenticated ? (
          <button
            type="button"
            className={styles.iconButton}
            onClick={() => navigate(ROUTES.SETTINGS)}
            aria-label="Preferences"
          >
            <FiSettings aria-hidden />
          </button>
        ) : (
          <button
            type="button"
            className={styles.iconButton}
            onClick={() => navigate(ROUTES.LOGIN)}
            aria-label="Login"
          >
            <FiUser aria-hidden />
          </button>
        )}
      </div>
    </header>
  )
}

TopStrip.displayName = 'TopStrip'
