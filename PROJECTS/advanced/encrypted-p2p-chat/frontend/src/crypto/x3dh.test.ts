// ===================
// © AngelaMos | 2026
// x3dh.test.ts
// ===================

import { describe, expect, it } from 'vitest'
import type { PreKeyBundle } from '../types'
import {
  generateIdentityKeyPair,
  generateOneTimePreKeys,
  generateSignedPreKey,
  initiateX3DH,
  receiveX3DH,
  verifySignedPreKey,
} from './x3dh'

describe('X3DH', () => {
  it('produces the same shared key on both sides with one-time prekey', async () => {
    const aliceIdentity = await generateIdentityKeyPair()
    const bobIdentity = await generateIdentityKeyPair()

    const bobSignedPreKey = await generateSignedPreKey(
      bobIdentity.ed25519_private
    )
    const [bobOPK] = await generateOneTimePreKeys(1)

    const bobBundle: PreKeyBundle = {
      identity_key: bobIdentity.x25519_public,
      identity_key_ed25519: bobIdentity.ed25519_public,
      signed_prekey: bobSignedPreKey.public_key,
      signed_prekey_signature: bobSignedPreKey.signature,
      one_time_prekey: bobOPK.public_key,
    }

    const aliceResult = await initiateX3DH(aliceIdentity, bobBundle)

    const bobSharedKey = await receiveX3DH(
      bobIdentity,
      bobSignedPreKey,
      bobOPK,
      aliceIdentity.x25519_public,
      aliceResult.ephemeral_public_key
    )

    expect(aliceResult.shared_key).toEqual(bobSharedKey)
    expect(aliceResult.shared_key.length).toBe(32)
    expect(aliceResult.used_one_time_prekey).toBe(true)
  })

  it('produces the same shared key on both sides without OPK', async () => {
    const aliceIdentity = await generateIdentityKeyPair()
    const bobIdentity = await generateIdentityKeyPair()

    const bobSignedPreKey = await generateSignedPreKey(
      bobIdentity.ed25519_private
    )

    const bobBundle: PreKeyBundle = {
      identity_key: bobIdentity.x25519_public,
      identity_key_ed25519: bobIdentity.ed25519_public,
      signed_prekey: bobSignedPreKey.public_key,
      signed_prekey_signature: bobSignedPreKey.signature,
      one_time_prekey: null,
    }

    const aliceResult = await initiateX3DH(aliceIdentity, bobBundle)

    const bobSharedKey = await receiveX3DH(
      bobIdentity,
      bobSignedPreKey,
      null,
      aliceIdentity.x25519_public,
      aliceResult.ephemeral_public_key
    )

    expect(aliceResult.shared_key).toEqual(bobSharedKey)
    expect(aliceResult.used_one_time_prekey).toBe(false)
  })

  it('verifies a valid signed prekey signature', async () => {
    const identity = await generateIdentityKeyPair()
    const signedPreKey = await generateSignedPreKey(identity.ed25519_private)

    const valid = await verifySignedPreKey(
      identity.ed25519_public,
      signedPreKey.public_key,
      signedPreKey.signature
    )
    expect(valid).toBe(true)
  })

  it('rejects a tampered signed prekey signature', async () => {
    const identity = await generateIdentityKeyPair()
    const signedPreKey = await generateSignedPreKey(identity.ed25519_private)

    const otherIdentity = await generateIdentityKeyPair()
    const otherSignedPreKey = await generateSignedPreKey(
      otherIdentity.ed25519_private
    )

    const valid = await verifySignedPreKey(
      identity.ed25519_public,
      signedPreKey.public_key,
      otherSignedPreKey.signature
    )
    expect(valid).toBe(false)
  })

  it('rejects an X3DH bundle with a forged signature', async () => {
    const aliceIdentity = await generateIdentityKeyPair()
    const bobIdentity = await generateIdentityKeyPair()
    const bobSignedPreKey = await generateSignedPreKey(
      bobIdentity.ed25519_private
    )

    const malloryIdentity = await generateIdentityKeyPair()
    const malloryForgedSpk = await generateSignedPreKey(
      malloryIdentity.ed25519_private
    )

    const tamperedBundle: PreKeyBundle = {
      identity_key: bobIdentity.x25519_public,
      identity_key_ed25519: bobIdentity.ed25519_public,
      signed_prekey: bobSignedPreKey.public_key,
      signed_prekey_signature: malloryForgedSpk.signature,
      one_time_prekey: null,
    }

    await expect(initiateX3DH(aliceIdentity, tamperedBundle)).rejects.toThrow(
      /Invalid signed prekey signature/
    )
  })
})
