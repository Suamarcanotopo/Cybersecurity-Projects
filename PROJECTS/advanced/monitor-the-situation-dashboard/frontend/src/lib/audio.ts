// ©AngelaMos | 2026
// audio.ts

import { useAudioStore } from '@/stores/audio'

let listenerAttached = false

function ensureCtx(): AudioContext {
  let ctx = useAudioStore.getState().ctx
  if (!ctx) {
    ctx = new AudioContext()
    useAudioStore.getState().setCtx(ctx)
  }
  return ctx
}

export async function loadChime(file: File): Promise<void> {
  const ctx = ensureCtx()
  const ab = await file.arrayBuffer()
  const buffer = await ctx.decodeAudioData(ab)
  useAudioStore.getState().setBuffer(buffer)
}

export function unlockOnFirstGesture(): void {
  if (useAudioStore.getState().unlocked) return
  if (listenerAttached) return
  listenerAttached = true

  const handler = async (): Promise<void> => {
    listenerAttached = false
    const ctx = ensureCtx()
    if (ctx.state === 'suspended') await ctx.resume()
    useAudioStore.getState().setUnlocked(true)
  }

  document.addEventListener('pointerdown', handler, { once: true })
}

export function playChime(): boolean {
  const { ctx, buffer, unlocked } = useAudioStore.getState()
  if (!ctx || !buffer || !unlocked) return false
  const src = ctx.createBufferSource()
  src.buffer = buffer
  src.connect(ctx.destination)
  src.start(0)
  return true
}
