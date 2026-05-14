// ===================
// © AngelaMos | 2026
// double-ratchet.test.ts
// ===================

import { describe, expect, it } from 'vitest'
import type { PreKeyBundle } from '../types'
import {
  decryptMessage,
  encryptMessage,
  initializeRatchetReceiver,
  initializeRatchetSender,
} from './double-ratchet'
import { exportPublicKey, generateX25519KeyPair } from './primitives'
import {
  generateIdentityKeyPair,
  generateOneTimePreKeys,
  generateSignedPreKey,
  initiateX3DH,
  receiveX3DH,
} from './x3dh'

async function bootstrapSession() {
  const aliceIdentity = await generateIdentityKeyPair()
  const bobIdentity = await generateIdentityKeyPair()
  const bobSignedPreKey = await generateSignedPreKey(bobIdentity.ed25519_private)
  const [bobOPK] = await generateOneTimePreKeys(1)

  const bobBundle: PreKeyBundle = {
    identity_key: bobIdentity.x25519_public,
    identity_key_ed25519: bobIdentity.ed25519_public,
    signed_prekey: bobSignedPreKey.public_key,
    signed_prekey_signature: bobSignedPreKey.signature,
    one_time_prekey: bobOPK.public_key,
  }

  const aliceX3DH = await initiateX3DH(aliceIdentity, bobBundle)
  const bobShared = await receiveX3DH(
    bobIdentity,
    bobSignedPreKey,
    bobOPK,
    aliceIdentity.x25519_public,
    aliceX3DH.ephemeral_public_key
  )

  const bobDH = await generateX25519KeyPair()
  const bobDHPublicBytes = await exportPublicKey(bobDH.publicKey)

  const aliceState = await initializeRatchetSender(
    'bob',
    aliceX3DH.shared_key,
    bobDHPublicBytes
  )

  const bobState = await initializeRatchetReceiver('alice', bobShared, bobDH)

  return { aliceState, bobState }
}

describe('Double Ratchet', () => {
  it('round-trips a single message', async () => {
    const { aliceState, bobState } = await bootstrapSession()

    const plaintext = new TextEncoder().encode('hello bob')
    const encrypted = await encryptMessage(aliceState, plaintext)
    const decrypted = await decryptMessage(bobState, encrypted)

    expect(new TextDecoder().decode(decrypted)).toBe('hello bob')
  })

  it('handles multiple messages in order', async () => {
    const { aliceState, bobState } = await bootstrapSession()

    const messages = ['m1', 'm2', 'm3', 'm4']
    const encryptedList = []
    for (const m of messages) {
      encryptedList.push(
        await encryptMessage(aliceState, new TextEncoder().encode(m))
      )
    }

    const decryptedTexts: string[] = []
    for (const enc of encryptedList) {
      const dec = await decryptMessage(bobState, enc)
      decryptedTexts.push(new TextDecoder().decode(dec))
    }

    expect(decryptedTexts).toEqual(messages)
    expect(aliceState.sending_message_number).toBe(messages.length)
    expect(bobState.receiving_message_number).toBe(messages.length)
  })

  it('handles out-of-order messages via skipped keys', async () => {
    const { aliceState, bobState } = await bootstrapSession()

    const m1 = await encryptMessage(aliceState, new TextEncoder().encode('m1'))
    const m2 = await encryptMessage(aliceState, new TextEncoder().encode('m2'))
    const m3 = await encryptMessage(aliceState, new TextEncoder().encode('m3'))

    const dec3 = await decryptMessage(bobState, m3)
    expect(new TextDecoder().decode(dec3)).toBe('m3')

    const dec1 = await decryptMessage(bobState, m1)
    expect(new TextDecoder().decode(dec1)).toBe('m1')

    const dec2 = await decryptMessage(bobState, m2)
    expect(new TextDecoder().decode(dec2)).toBe('m2')
  })

  it('refuses to decrypt a tampered ciphertext', async () => {
    const { aliceState, bobState } = await bootstrapSession()

    const encrypted = await encryptMessage(
      aliceState,
      new TextEncoder().encode('plaintext')
    )
    encrypted.ciphertext[0] ^= 0xff

    await expect(decryptMessage(bobState, encrypted)).rejects.toThrow()
  })
})
