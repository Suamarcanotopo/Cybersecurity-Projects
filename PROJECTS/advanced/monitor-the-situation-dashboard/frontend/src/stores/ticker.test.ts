// ©AngelaMos | 2026
// ticker.test.ts

import { beforeEach, describe, expect, it } from 'vitest'
import { useTicker } from './ticker'

describe('useTicker', () => {
  beforeEach(() => {
    useTicker.getState().clear()
  })

  it('caps at 50 entries oldest-out', () => {
    for (let i = 0; i < 100; i++) {
      useTicker.getState().push({
        id: `e${i}`,
        source: 'wiki',
        headline: `headline ${i}`,
        ts: Date.now() + i,
      })
    }
    expect(useTicker.getState().items).toHaveLength(50)
    // oldest survivors are e50..e99
    expect(useTicker.getState().items[0].id).toBe('e50')
    expect(useTicker.getState().items.at(-1)?.id).toBe('e99')
  })

  it('deduplicates by id', () => {
    const item = { id: 'dup', source: 'gdelt', headline: 'h', ts: 0 }
    useTicker.getState().push(item)
    useTicker.getState().push(item)
    expect(useTicker.getState().items).toHaveLength(1)
  })
})
