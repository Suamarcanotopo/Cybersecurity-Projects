// ©AngelaMos | 2026
// heartbeat.ts

import { create } from 'zustand'

interface HeartbeatStore {
  lastTs: number | null
  beat: () => void
}

export const useHeartbeat = create<HeartbeatStore>((set) => ({
  lastTs: null,
  beat: () => set({ lastTs: Date.now() }),
}))
