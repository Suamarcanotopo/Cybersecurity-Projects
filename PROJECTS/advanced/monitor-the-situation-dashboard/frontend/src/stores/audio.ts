// ©AngelaMos | 2026
// audio.ts

import { create } from 'zustand'

interface AudioStore {
  ctx: AudioContext | null
  buffer: AudioBuffer | null
  unlocked: boolean
  setCtx: (ctx: AudioContext | null) => void
  setBuffer: (b: AudioBuffer | null) => void
  setUnlocked: (u: boolean) => void
}

export const useAudioStore = create<AudioStore>((set) => ({
  ctx: null,
  buffer: null,
  unlocked: false,
  setCtx: (ctx) => set({ ctx }),
  setBuffer: (buffer) => set({ buffer }),
  setUnlocked: (unlocked) => set({ unlocked }),
}))
