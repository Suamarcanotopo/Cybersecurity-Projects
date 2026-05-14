# Implementation Guide

This document walks through every significant piece of the encrypted P2P chat, file by file, explaining not just what the code does but why each decision was made. If you want to build something like Signal from scratch, this is the map.

---

## File Structure Walkthrough

```
backend/
 app/
 api/
 auth.py # WebAuthn registration/login endpoints
 encryption.py # Key upload, prekey bundle retrieval
 rooms.py # Chat room creation and listing
 websocket.py # WebSocket endpoint (receives raw frames)
 core/
 passkey/
 passkey_manager.py # WebAuthn: registration, auth, clone detection
 dependencies.py # current_user, issue_session, revoke_session
 websocket_manager.py # Connection pool, heartbeats, live query sub
 surreal_manager.py # SurrealDB client (messages, live queries)
 redis_manager.py # Redis client (sessions, challenges)
 exceptions.py # Custom exception hierarchy
 exception_handlers.py # FastAPI exception-to-HTTP mappings
 enums.py # Presence status enum
 models/
 Base.py # SQLModel engine, async session maker
 User.py # User table (id, username, webauthn_user_handle, ...)
 Credential.py # WebAuthn credential storage (BE/BS, sign_count)
 IdentityKey.py # X25519 + Ed25519 identity public keys (no privates)
 SignedPrekey.py # Signed prekey publics + signature
 OneTimePrekey.py # Single-use prekey publics (is_used flag)
 schemas/
 auth.py # Pydantic schemas for registration/auth flows
 websocket.py # Pydantic schemas for WS message types
 surreal.py # Pydantic schemas for SurrealDB documents
 rooms.py # Pydantic schemas for room operations
 common.py # Shared response schemas
 services/
 auth_service.py # User creation, credential management, search
 prekey_service.py # Public-only prekey storage + bundle lookup
 message_service.py # Pass-through ciphertext writer
 websocket_service.py # WS routing + per-user rate cap + membership
 presence_service.py # Online/offline/away status via SurrealDB
 config.py # All constants + Settings (env vars)
 factory.py # FastAPI app factory with middleware
 main.py # Uvicorn entry point

frontend/
 src/
 crypto/
 primitives.ts # Low-level WebCrypto: X25519, Ed25519, AES-GCM, HKDF, HMAC
 x3dh.ts # Client-side X3DH: generate keys, initiate, receive
 double-ratchet.ts # Client-side Double Ratchet: init, encrypt, decrypt, serialize
 crypto-service.ts # High-level orchestrator: session management, key upload
 key-store.ts # IndexedDB persistence for all key material
 message-store.ts # Message history persistence
 websocket/
 websocket-manager.ts # WS connection, reconnect, heartbeat, message queue
 message-handlers.ts # Dispatch incoming WS messages to stores
 stores/
 auth.store.ts # Authentication state (nanostores)
 session.store.ts # Session token management
 messages.store.ts # Message list per room
 rooms.store.ts # Room list and active room
 presence.store.ts # Online status per user
 typing.store.ts # Typing indicator state
 ui.store.ts # UI state (sidebar open, modals)
 settings.store.ts # User preferences
 services/
 auth.service.ts # WebAuthn browser API calls
 room.service.ts # Room CRUD via API
 components/
 Auth/ # Login, Register, PasskeyButton
 Chat/ # MessageList, ChatInput, ConversationList, etc.
 Layout/ # AppShell, Sidebar, Header, ProtectedRoute
 UI/ # Button, Modal, Input, Tooltip, etc.
 pages/
 Chat.tsx # Main chat page (conversation + message pane)
 Login.tsx # Login page
 Register.tsx # Registration page
 Home.tsx # Landing page
 NotFound.tsx # 404
 types/
 encryption.ts # Type definitions for crypto structures
 chat.ts # Message and room types
 websocket.ts # WS message types
 auth.ts # Auth types
 guards.ts # Runtime type guards for WS messages
 api.ts # API response types
 components.ts # Component prop types
 index.ts # Re-exports + constants
 lib/
 api-client.ts # HTTP client for REST endpoints
 base64.ts # Base64 helpers
 validators.ts # Input validation
 date.ts # Date formatting
 config.ts # Frontend constants (URLs, timeouts)
```

---

## Building the X3DH Key Exchange

X3DH (Extended Triple Diffie-Hellman) solves a specific problem: Alice wants to send Bob an encrypted message, but Bob is offline. They have never communicated before. There is no way to do a live handshake. X3DH lets Alice compute a shared secret using Bob's pre-published keys, so that when Bob comes back online, he can derive the same secret and decrypt everything Alice sent while he was away.

### Step 1: Key Generation

The foundation of X3DH is generating two types of identity keypairs per user. Here is the X25519 identity key generation from `frontend/src/crypto/x3dh.ts`:

```python
def generate_identity_keypair_x25519(self) -> tuple[str, str]:
 private_key = X25519PrivateKey.generate
 public_key = private_key.public_key

 private_bytes = private_key.private_bytes(
 encoding = serialization.Encoding.Raw,
 format = serialization.PrivateFormat.Raw,
 encryption_algorithm = serialization.NoEncryption
 )
 public_bytes = public_key.public_bytes(
 encoding = serialization.Encoding.Raw,
 format = serialization.PublicFormat.Raw
 )

 return (
 bytes_to_base64url(private_bytes),
 bytes_to_base64url(public_bytes)
 )
```

There is also `generate_identity_keypair_ed25519` at `frontend/src/crypto/x3dh.ts`, which follows the exact same pattern but uses `Ed25519PrivateKey.generate` instead.

**Why Raw encoding?** PEM and DER formats include metadata headers, algorithm identifiers, and ASN.1 structure. That is wasted bytes when you already know the algorithm on both sides. Raw encoding gives you exactly 32 bytes for X25519 and 32 bytes for Ed25519. That is the minimum footprint, and it maps directly to what the WebCrypto API expects on the frontend when importing with `importKey("raw", ...)`.

**Why base64url?** The keys need to travel through JSON (over HTTP and WebSocket) and get stored in PostgreSQL text columns. Hex encoding doubles the size (32 bytes becomes 64 characters). Standard base64 uses `+` and `/` characters that require URL encoding. Base64url uses `-` and `_` instead, which are safe in URLs, JSON, and query parameters without escaping. The `webauthn.helpers` library provides `bytes_to_base64url` and `base64url_to_bytes`, so we piggyback on those rather than rolling our own.

**Why two key types (X25519 and Ed25519)?** X25519 is a Diffie-Hellman function. It takes two keys and produces a shared secret. That is what you need for the actual key agreement. But X25519 cannot produce signatures. You cannot prove "I am the owner of this public key" with X25519 alone. Ed25519 is a signature algorithm that operates on the same curve family (Curve25519), so key generation is equally fast. The Ed25519 identity key signs the Signed Prekey, proving to Alice that Bob actually published that prekey and not some attacker in the middle. Separating the two key types follows the cryptographic principle of using distinct keys for distinct purposes. If you used a single key for both DH and signing, a vulnerability in one operation could compromise the other.

### Step 2: Signed Prekey Creation

The Signed Prekey (SPK) is a semi-static X25519 key that gets rotated every 48 hours. Here is `generate_signed_prekey` from `frontend/src/crypto/x3dh.ts`:

```python
def generate_signed_prekey(self,
 identity_private_key_ed25519: str) -> tuple[str,
 str,
 str]:
 spk_private = X25519PrivateKey.generate
 spk_public = spk_private.public_key

 spk_private_bytes = spk_private.private_bytes(
 encoding = serialization.Encoding.Raw,
 format = serialization.PrivateFormat.Raw,
 encryption_algorithm = serialization.NoEncryption
 )
 spk_public_bytes = spk_public.public_bytes(
 encoding = serialization.Encoding.Raw,
 format = serialization.PublicFormat.Raw
 )

 identity_private_bytes = base64url_to_bytes(identity_private_key_ed25519)
 identity_private = Ed25519PrivateKey.from_private_bytes(
 identity_private_bytes
 )

 signature = identity_private.sign(spk_public_bytes)

 return (
 bytes_to_base64url(spk_private_bytes),
 bytes_to_base64url(spk_public_bytes),
 bytes_to_base64url(signature)
 )
```

**Why sign with Ed25519?** The signature proves that Bob's long-term Ed25519 identity key endorses this particular SPK. When Alice fetches Bob's prekey bundle, she verifies this signature before performing the DH operations. Without the signature, a man-in-the-middle could substitute their own SPK public key into Bob's bundle. Alice would compute a shared secret with the attacker instead of Bob, and the attacker could relay messages between them while reading everything.

**What does the signature prove?** It proves exactly one thing: "The entity controlling the Ed25519 private key corresponding to Bob's published Ed25519 public key chose to sign this specific SPK public key." That binds the SPK to Bob's identity.

**Why not self-sign with X25519?** X25519 is a DH function, not a signature scheme. There is no `sign` method on an X25519 key. You could theoretically convert between Curve25519 and Ed25519 key formats (they share the same underlying curve), but doing that conversion is a footgun. It is error-prone, not all libraries support it, and it violates the principle of key separation. Using a dedicated Ed25519 signing key is simpler and safer.

### Step 3: Prekey Bundle Assembly

When Alice wants to message Bob, the server assembles Bob's prekey bundle. This happens in `backend/app/services/prekey_service.py`:

```python
async def get_prekey_bundle(
 self,
 session: AsyncSession,
 user_id: UUID
) -> PreKeyBundle:
 # Fetch identity key
 ik_statement = select(IdentityKey).where(IdentityKey.user_id == user_id)
 ...
 # Fetch active signed prekey
 spk_statement = select(SignedPrekey).where(
 SignedPrekey.user_id == user_id,
 SignedPrekey.is_active
 ).order_by(SignedPrekey.created_at.desc)
 ...
 if not signed_prekey:
 signed_prekey = await self.rotate_signed_prekey(session, user_id)

 # Fetch one unused OPK
 opk_statement = select(OneTimePrekey).where(
 OneTimePrekey.user_id == user_id,
 not OneTimePrekey.is_used
 ).limit(1)
 ...
 if one_time_prekey:
 one_time_prekey.is_used = True
 ...
```

**Why auto-rotate?** If Bob's signed prekey expired and there are no active ones, the bundle fetch would fail. Auto-rotation at `backend/app/services/prekey_service.py` ensures there is always an active SPK. The rotation generates a new X25519 keypair, signs it with Bob's Ed25519 identity key, marks old SPKs as inactive, and sets a 48-hour expiry (`SIGNED_PREKEY_ROTATION_HOURS = 48` in `config.py`).

**Why mark OPK as used?** One-Time Prekeys provide forward secrecy for the initial handshake. Each OPK is consumed exactly once. When Alice fetches Bob's bundle, the server marks that OPK as `is_used = True` and commits the change. If a second person also tries to start a conversation with Bob around the same time, they get a different OPK (or none at all). This single-use guarantee means that even if Bob's long-term keys are later compromised, an attacker cannot retroactively compute the shared secret for conversations that used an OPK, because the OPK private key was consumed and the DH output from it cannot be reconstructed from the other keys alone.

**What happens if no OPK is available?** The protocol still works. The `PreKeyBundle` dataclass has `one_time_prekey: str | None = None`. When the bundle is assembled without an OPK, the X3DH sender side simply computes `dh1 + dh2 + dh3` instead of `dh1 + dh2 + dh3 + dh4`. This gives slightly weaker forward secrecy for the initial handshake (it relies on the signed prekey not being compromised), but the Double Ratchet provides forward secrecy for all subsequent messages regardless. The system compensates by calling `replenish_one_time_prekeys` periodically to maintain a pool of 100 OPKs (`DEFAULT_ONE_TIME_PREKEY_COUNT = 100` in `config.py`).

### Step 4: X3DH Sender Side

This is the core of the initial key agreement. Here is the DH operations from `frontend/src/crypto/x3dh.ts`:

```python
dh1 = alice_ik_private.exchange(bob_spk_public)
dh2 = alice_ek_private.exchange(bob_ik_public)
dh3 = alice_ek_private.exchange(bob_spk_public)

used_one_time_prekey = False
if bob_bundle.one_time_prekey:
 bob_opk_public_bytes = base64url_to_bytes(bob_bundle.one_time_prekey)
 bob_opk_public = X25519PublicKey.from_public_bytes(bob_opk_public_bytes)
 dh4 = alice_ek_private.exchange(bob_opk_public)
 key_material = dh1 + dh2 + dh3 + dh4
 used_one_time_prekey = True
else:
 key_material = dh1 + dh2 + dh3

f = b'\xff' * X25519_KEY_SIZE
hkdf = HKDF(
 algorithm = hashes.SHA256,
 length = X25519_KEY_SIZE,
 salt = b'\x00' * X25519_KEY_SIZE,
 info = b'X3DH',
)
shared_key = hkdf.derive(f + key_material)
```

Before this code runs, the sender verifies the signed prekey signature at `frontend/src/crypto/x3dh.ts`. If verification fails, a `ValueError` is raised and the exchange aborts. This is the MITM protection.

**Each DH operation explained:**

- **dh1 = IK_A.exchange(SPK_B)** -- Alice's long-term identity key with Bob's signed prekey. This provides mutual authentication: only the real Alice and the real Bob can compute this value.
- **dh2 = EK_A.exchange(IK_B)** -- Alice's ephemeral key with Bob's identity key. This provides forward secrecy from Alice's side: the ephemeral key is used once and discarded.
- **dh3 = EK_A.exchange(SPK_B)** -- Alice's ephemeral key with Bob's signed prekey. This provides additional mixing. Even if either IK_A or IK_B is compromised, this DH output is still unknown to the attacker.
- **dh4 = EK_A.exchange(OPK_B)** (optional) -- Alice's ephemeral key with Bob's one-time prekey. This provides replay protection and additional forward secrecy, because the OPK is used exactly once.

**Why the 0xFF padding?** The line `f = b'\xff' * X25519_KEY_SIZE` prepends 32 bytes of `0xFF` before the key material fed into HKDF. This is directly from the Signal specification. The purpose is to ensure the HKDF input is never all zeros. If all four DH outputs happened to be zero (which would indicate a catastrophic failure, like someone substituting the identity point), the `0xFF` padding ensures the HKDF input still has high entropy. It is a belt-and-suspenders defense.

**Why salt of zeros?** The Signal specification defines the salt as 32 bytes of `0x00`. HKDF requires a salt, and using all zeros is equivalent to using no salt (HKDF treats a zero-length salt as a string of zeros anyway). The salt is fixed rather than random because both sides need to derive the same key without communicating the salt. If you used a random salt, you would need to transmit it, which adds complexity and message size for no security benefit here (the DH outputs already provide the randomness).

**Why info="X3DH"?** The `info` parameter in HKDF is a domain separation string. It ensures that the derived key is bound to this specific protocol. If the same key material were accidentally reused in a different context (say, a TLS handshake), the info string would produce a different derived key. This prevents cross-protocol attacks.

**Associated data: IK_A || IK_B.** After deriving the shared key, the code computes `associated_data = alice_ik_public_bytes + bob_ik_public_bytes` at `frontend/src/crypto/x3dh.ts`. This associated data is later passed to AES-GCM as the AAD (Additional Authenticated Data). It binds the encrypted messages to the specific pair of identity keys that performed the handshake. If an attacker tries to redirect messages between different users, the AAD check will fail during decryption.

### Step 5: X3DH Receiver Side

The receiver-side logic lives at `frontend/src/crypto/x3dh.ts`. The operations are mirrored:

```python
dh1 = bob_spk_private.exchange(alice_ik_public) # mirrors alice_ik.exchange(bob_spk)
dh2 = bob_ik_private.exchange(alice_ek_public) # mirrors alice_ek.exchange(bob_ik)
dh3 = bob_spk_private.exchange(alice_ek_public) # mirrors alice_ek.exchange(bob_spk)
dh4 = bob_opk_private.exchange(alice_ek_public) # mirrors alice_ek.exchange(bob_opk)
```

This works because of how Diffie-Hellman is defined: `A_private.exchange(B_public) == B_private.exchange(A_public)`. The math is commutative. Both sides compute the same four 32-byte DH outputs, concatenate them in the same order, and derive the same shared key through the same HKDF parameters (zero salt, `X3DH` info, `0xFF` padding).

The receiver also constructs `associated_data = alice_ik_public_bytes + bob_ik_public_bytes` in the same order (Alice's IK first, Bob's IK second) at `frontend/src/crypto/x3dh.ts`. Order matters. If Alice put hers first on the sender side but Bob reversed the order on the receiver side, the associated data would not match and decryption would fail.

### Common Mistakes

**BAD: Using random salt in HKDF**

```python
# WRONG - breaks compatibility between sender and receiver
salt = os.urandom(32)
hkdf = HKDF(algorithm=hashes.SHA256, length=32, salt=salt, info=b'X3DH')
```

If you use a random salt, the sender and receiver will derive different shared keys. The sender would need to transmit the salt alongside the ephemeral key, and at that point you have added complexity for no security gain since the DH outputs already provide the randomness.

**BAD: Forgetting to verify signed prekey signature**

```python
# WRONG - allows MITM to substitute their own SPK
def perform_x3dh_sender(self, alice_identity_private_x25519, bob_bundle, ...):
 # Skipped: self.verify_signed_prekey(...)
 alice_ik_private_bytes = base64url_to_bytes(alice_identity_private_x25519)
 ...
```

Without signature verification, an attacker who controls the network can replace Bob's SPK public key with their own. Alice would compute a shared secret with the attacker. The attacker then performs X3DH with Bob using Bob's real SPK, and relays messages between them. Neither Alice nor Bob detects the interception. The fix is on `frontend/src/crypto/x3dh.ts`: verify before exchanging.

**BAD: Reusing one-time prekeys**

```python
# WRONG - breaks forward secrecy for initial handshake
opk = get_opk_for_user(user_id)
# forgot to mark as used
# another conversation uses the same OPK
```

If two conversations use the same OPK, an attacker who later compromises Bob's OPK private key can compute the DH4 output for both conversations. That defeats the purpose of single-use keys. The fix is at `backend/app/services/prekey_service.py`: `one_time_prekey.is_used = True` immediately upon retrieval, followed by `session.commit`.

### Frontend X3DH Implementation

The frontend mirrors the backend X3DH in TypeScript using the WebCrypto API. The client-side sender logic lives in `x3dh.ts`:

```typescript
export async function initiateX3DH(
 identityKeyPair: IdentityKeyPair,
 recipientBundle: PreKeyBundle
): Promise<X3DHResult> {
 const signatureValid = await verifySignedPreKey(
 recipientBundle.identity_key_ed25519,
 recipientBundle.signed_prekey,
 recipientBundle.signed_prekey_signature
 )
 if (!signatureValid) {
 throw new Error("Invalid signed prekey signature")
 }
 ...
 const dh1 = await x25519DeriveSharedSecret(senderIdentityPrivate, recipientSignedPreKeyPublic)
 const dh2 = await x25519DeriveSharedSecret(ephemeralKeyPair.privateKey, recipientIdentityPublic)
 const dh3 = await x25519DeriveSharedSecret(ephemeralKeyPair.privateKey, recipientSignedPreKeyPublic)
 ...
 const sharedKey = await hkdfDerive(concatenated, EMPTY_SALT, X3DH_INFO, 32)
```

The HKDF derivation used here is from `frontend/src/crypto/primitives.ts`:

```typescript
export async function hkdfDerive(
 inputKeyMaterial: Uint8Array,
 salt: Uint8Array,
 info: Uint8Array,
 outputLength: number = HKDF_OUTPUT_SIZE
): Promise<Uint8Array> {
 const baseKey = await subtle.importKey(
 "raw", inputKeyMaterial.buffer as ArrayBuffer,
 { name: "HKDF" }, false, ["deriveBits"]
 )
 const derivedBits = await subtle.deriveBits(
 { name: "HKDF", hash: "SHA-256",
 salt: salt.buffer as ArrayBuffer,
 info: info.buffer as ArrayBuffer },
 baseKey, outputLength * 8
 )
 return new Uint8Array(derivedBits)
}
```

There is an important difference between the backend and frontend HKDF calls. The backend prepends `0xFF * 32` to the key material before calling HKDF (following the Signal spec literally). The frontend passes the concatenated DH outputs directly. Both produce a 32-byte shared key, but the padding difference means the backend and frontend X3DH implementations are not interchangeable for the same conversation. This is by design: in the E2E model, the frontend performs X3DH entirely on the client side, and the backend's X3DH is used only for the server-assisted key initialization path (which is a deprecated fallback). When client-side encryption is active, only the frontend's `x3dh.ts` code runs.

The WebCrypto API's `subtle.deriveBits` with the `HKDF` algorithm handles the extract-then-expand steps internally. You provide the input key material, a salt, an info string, and the desired output length in bits (not bytes, which is why `outputLength * 8` appears). The `importKey` call with `{ name: "HKDF" }` creates a non-extractable key object suitable only for derivation, which prevents the raw key material from being accidentally exported or misused.

The receiver-side X3DH in `x3dh.ts` mirrors the sender with the same key swaps as the Python version. The commutative property of ECDH ensures both sides derive the same 32-byte shared key.

---

## Building the Double Ratchet

The Double Ratchet provides ongoing forward secrecy and break-in recovery after the initial X3DH handshake. "Forward secrecy" means compromising the current key does not reveal past messages. "Break-in recovery" means that even if an attacker steals the current keys, future messages become unreadable once new DH ratchet steps occur.

### Initialization

The sender initializes via `initializeRatchetSender` in `frontend/src/crypto/double-ratchet.ts`:

```ts
export async function initializeRatchetSender(
 peerId: string,
 sharedKey: Uint8Array,
 peerPublicKey: Uint8Array,
): Promise<DoubleRatchetState> {
 const dhKeyPair = await generateX25519KeyPair
 const dhPublicKey = await exportPublicKey(dhKeyPair.publicKey)
 const peerKey = await importX25519PublicKey(peerPublicKey)
 const dhOutput = await x25519DeriveSharedSecret(dhKeyPair.privateKey, peerKey)

 // KDF_RK per spec: HKDF(salt = previous_root_key, IKM = dh_output, info = "DoubleRatchet")
 const derivedKeys = await hkdfDerive(dhOutput, sharedKey, RATCHET_INFO, 64)
 const rootKey = derivedKeys.slice(0, 32)
 const sendingChainKey = derivedKeys.slice(32, 64)

 return { peer_id: peerId, root_key: rootKey, sending_chain_key: sendingChainKey, /* ... */ }
}
```

The receiver initializes via `initializeRatchetReceiver`:

```ts
export async function initializeRatchetReceiver(
 peerId: string,
 sharedKey: Uint8Array,
 dhKeyPair: CryptoKeyPair,
): Promise<DoubleRatchetState> {
 const dhPublicKey = await exportPublicKey(dhKeyPair.publicKey)
 return {
 peer_id: peerId,
 root_key: sharedKey,
 sending_chain_key: new Uint8Array(0),
 receiving_chain_key: null,
 dh_private_key: dhKeyPair,
 dh_public_key: dhPublicKey,
 dh_peer_public_key: null,
 /* ... */
 }
}
```

**Why does the sender do an extra DH step?** The sender generates a fresh DH keypair and immediately performs a DH exchange with Bob's SPK public key. This produces a `dh_output` which gets fed into `_kdf_rk` along with the X3DH `shared_key` to derive the first `root_key` and `sending_chain_key`. This extra step means the first message already has a DH ratchet contribution beyond the X3DH output. The receiver, by contrast, does not perform this step during initialization. It simply stores the X3DH shared key as the root key and waits for the first message, which will carry the sender's new DH public key and trigger the receiver's first ratchet step.

### KDF Chain Operations

The root key chain derivation at `frontend/src/crypto/double-ratchet.ts`:

```python
def _kdf_rk(self, root_key: bytes, dh_output: bytes) -> tuple[bytes, bytes]:
 hkdf = HKDF(
 algorithm = hashes.SHA256,
 length = HKDF_OUTPUT_SIZE * 2,
 salt = root_key,
 info = b'',
 )
 output = hkdf.derive(dh_output)
 new_root_key = output[: HKDF_OUTPUT_SIZE]
 new_chain_key = output[HKDF_OUTPUT_SIZE :]
 return new_root_key, new_chain_key
```

`_kdf_rk` is the root chain KDF. It runs every time a DH ratchet step occurs (when the sender or receiver generates a new DH keypair). The `root_key` is used as the HKDF salt, and the fresh DH output is the input key material. HKDF produces 64 bytes (`HKDF_OUTPUT_SIZE * 2 = 64`), which is split in half: the first 32 bytes become the new root key, and the second 32 bytes become the new chain key. The root key never directly encrypts anything. It acts as a "master key" that seeds each new chain. Because the root key is updated with fresh DH output every ratchet step, even if an attacker compromises the current root key, the next ratchet step will incorporate a new DH output that the attacker does not know (assuming the DH private key is secure), and the root key will be "healed." This is the break-in recovery property.

The empty `info` parameter is intentional. The Signal spec does not use an info string for the root chain KDF. Domain separation happens implicitly because the root chain HKDF always uses the root key as salt, whereas the X3DH HKDF uses a zero salt. Different salts produce different outputs even with the same input, so there is no cross-contamination.

The chain key derivation at `frontend/src/crypto/double-ratchet.ts`:

```python
def _kdf_ck(self, chain_key: bytes) -> tuple[bytes, bytes]:
 h_chain = hmac.HMAC(chain_key, hashes.SHA256)
 h_chain.update(b'\x01')
 next_chain_key = h_chain.finalize

 h_message = hmac.HMAC(chain_key, hashes.SHA256)
 h_message.update(b'\x02')
 message_key = h_message.finalize

 return next_chain_key, message_key
```

**Why HMAC with 0x01 and 0x02?** The chain key needs to produce two outputs: the next chain key and the message key. Using HMAC with different single-byte constants is the simplest way to derive two independent values from one input. `0x01` produces the next chain key, `0x02` produces the message key. The constants are arbitrary but fixed by convention (the Signal spec uses these exact values). The important thing is that they are different, so the two HMAC outputs are cryptographically independent.

**Why two separate HMACs?** You cannot reuse an HMAC object after calling `finalize` in the Python `cryptography` library. Each HMAC computation is a fresh instance. Even if you could reuse it, producing two different outputs from the same key requires two different inputs, which means two operations.

**What is the one-way property?** Given `next_chain_key = HMAC(chain_key, 0x01)`, you cannot compute `chain_key` from `next_chain_key`. HMAC is a one-way function. This means that if an attacker obtains a message key for message N, they cannot derive the chain key that produced it, and therefore cannot derive message keys for messages 0 through N-1. This is forward secrecy within a single chain.

### Message Encryption

Here is the encrypt path from `frontend/src/crypto/double-ratchet.ts`:

```python
def encrypt_message(self, state, plaintext, associated_data):
 state.sending_chain_key, message_key = self._kdf_ck(state.sending_chain_key)
 nonce, ciphertext = self._encrypt_with_message_key(message_key, plaintext, associated_data)

 if state.dh_private_key:
 dh_public = state.dh_private_key.public_key
 dh_public_bytes = dh_public.public_bytes(
 encoding = serialization.Encoding.Raw,
 format = serialization.PublicFormat.Raw
 )
 else:
 dh_public_bytes = b'\x00' * X25519_KEY_SIZE

 encrypted_msg = EncryptedMessage(
 ciphertext = ciphertext,
 nonce = nonce,
 dh_public_key = dh_public_bytes,
 message_number = state.sending_message_number,
 previous_chain_length = state.previous_sending_chain_length
 )
 state.sending_message_number += 1
 return encrypted_msg
```

And the underlying AES-GCM encryption at `frontend/src/crypto/double-ratchet.ts`:

```python
def _encrypt_with_message_key(self, message_key, plaintext, associated_data):
 aesgcm = AESGCM(message_key)
 nonce = os.urandom(AES_GCM_NONCE_SIZE)
 ciphertext = aesgcm.encrypt(nonce, plaintext, associated_data)
 return nonce, ciphertext
```

**Why include dh_public_key in the header?** The recipient needs the sender's current DH public key to determine whether to perform a DH ratchet step. If the DH public key in the message header differs from the last known peer DH key, the recipient knows the sender has ratcheted, and the recipient must also ratchet to derive the correct receiving chain key. Without this header field, the recipient would have no way to know which chain to use.

**Why track message_number?** Messages can arrive out of order over WebSocket. If the recipient receives message 5 before message 3, it needs to know that messages 3 and 4 were skipped. The `message_number` tells the recipient exactly which position in the chain produced this message's key. The `previous_chain_length` tells the recipient how many messages were sent on the previous chain before the sender ratcheted, which is needed to compute skipped keys from the old chain.

### Message Decryption

The decrypt path at `frontend/src/crypto/double-ratchet.ts` handles three distinct cases:

```python
def decrypt_message(self, state, encrypted_msg, associated_data):
 # Case 1: Check if we already stored this message's key (out-of-order)
 skipped_key = self._try_skipped_message_key(
 state, encrypted_msg.dh_public_key, encrypted_msg.message_number
 )
 if skipped_key:
 return self._decrypt_with_message_key(
 skipped_key, encrypted_msg.nonce, encrypted_msg.ciphertext, associated_data
 )

 # Case 2: New DH ratchet key means sender ratcheted
 if encrypted_msg.dh_public_key != state.dh_peer_public_key:
 if state.dh_peer_public_key:
 self._store_skipped_message_keys(
 state, encrypted_msg.previous_chain_length, state.dh_peer_public_key
 )
 self._dh_ratchet_receive(state, encrypted_msg.dh_public_key)

 # Case 3: Message number ahead of current position means skipped messages
 if encrypted_msg.message_number > state.receiving_message_number:
 self._store_skipped_message_keys(
 state, encrypted_msg.message_number, encrypted_msg.dh_public_key
 )

 # Advance chain and decrypt
 state.receiving_chain_key, message_key = self._kdf_ck(state.receiving_chain_key)
 state.receiving_message_number += 1

 plaintext = self._decrypt_with_message_key(
 message_key, encrypted_msg.nonce, encrypted_msg.ciphertext, associated_data
 )
 return plaintext
```

**Case 1: Skipped key hit.** The message key was already computed and stored during a previous skip operation. Pop it from the dict, decrypt, done. This handles previously skipped messages arriving late.

**Case 2: New ratchet step.** The DH public key in the message header does not match the last known peer public key. This means the sender performed a DH ratchet step. The receiver must first store skipped keys for any remaining messages on the old chain (up to `previous_chain_length`), then perform its own DH ratchet step to derive the new receiving chain key.

**Case 3: Same chain, skipped messages.** The message number is ahead of the current position on the same chain. The receiver must advance the chain key, storing each intermediate message key, until it reaches the correct position.

### Out-of-Order Handling

The skip mechanism at `frontend/src/crypto/double-ratchet.ts`:

```python
def _store_skipped_message_keys(self, state, until_message_number, dh_public_key):
 num_to_skip = until_message_number - state.receiving_message_number

 if num_to_skip > self.max_skip:
 raise ValueError(
 f"Cannot skip {num_to_skip} messages "
 f"(MAX_SKIP={self.max_skip})"
 )

 if len(state.skipped_message_keys) + num_to_skip > self.max_cache:
 self._evict_oldest_skipped_keys(state, num_to_skip)

 chain_key = state.receiving_chain_key
 for msg_num in range(state.receiving_message_number, until_message_number):
 chain_key, message_key = self._kdf_ck(chain_key)
 state.skipped_message_keys[(dh_public_key, msg_num)] = message_key

 state.receiving_chain_key = chain_key
```

**MAX_SKIP = 1000** (`config.py`). If an attacker sends a message claiming `message_number = 999999999`, the receiver would need to compute 999999999 HMAC operations to derive all the intermediate keys. That is a denial-of-service attack. The limit of 1000 means the receiver will reject any message that would require skipping more than 1000 positions. In practice, even aggressive out-of-order delivery rarely exceeds a few dozen skipped messages.

**MAX_CACHE = 2000** (`config.py`). Even with the skip limit, a determined attacker could slowly accumulate skipped keys by sending many small gaps. The cache limit prevents unbounded memory growth. When the cache is full, `_evict_oldest_skipped_keys` removes the oldest entries to make room. Oldest entries are the ones most likely to be genuinely lost (if a message has not arrived after 2000 other skipped keys were stored, it is probably never coming).

### Common Mistakes

**Not checking max skip (DoS via huge message number gaps).** Without the `num_to_skip > self.max_skip` check, an attacker can force the receiver to compute millions of HMAC operations by sending a single message with a large message number. The CPU cost is linear in the gap size.

**Not evicting old skipped keys (memory exhaustion).** Without eviction, the `skipped_message_keys` dict grows without bound. An attacker can cause OOM by sending many messages with incrementing but non-sequential message numbers across multiple ratchet steps.

**Reusing nonces (catastrophic for AES-GCM).** AES-GCM uses a 12-byte nonce. If the same nonce is used twice with the same key, an attacker can XOR the two ciphertexts to eliminate the keystream and recover both plaintexts. The code uses `os.urandom(AES_GCM_NONCE_SIZE)` at `frontend/src/crypto/double-ratchet.ts` for a fresh random nonce every time. Since each message key is used exactly once (each chain key advances after derivation), and each message key gets a random nonce, the probability of a collision is negligible. But if someone modified the code to reuse message keys, the random nonce would be the only defense, and with 12 bytes, birthday collisions become likely after about 2^48 messages under the same key.

---

## Building WebAuthn Authentication

### Registration Flow

Registration is handled in `backend/app/core/passkey/passkey_manager.py`. The server generates registration options:

```python
def generate_registration_options(
 self, user_id, username, display_name, exclude_credentials
):
 challenge = secrets.token_bytes(WEBAUTHN_CHALLENGE_BYTES)
 ...
 options = generate_registration_options(
 rp_id = self.rp_id,
 rp_name = self.rp_name,
 user_id = user_id,
 user_name = username,
 challenge = challenge,
 attestation = AttestationConveyancePreference.NONE,
 authenticator_selection = AuthenticatorSelectionCriteria(
 resident_key = ResidentKeyRequirement.REQUIRED,
 user_verification = UserVerificationRequirement.PREFERRED,
 ),
 exclude_credentials = exclude_creds,
 )
```

**ResidentKeyRequirement.REQUIRED** means the authenticator must store the credential on the device itself (a "discoverable credential" or "passkey"). This allows usernameless login: the user just taps their security key or uses biometrics, and the authenticator presents the credential without the user typing a username. Without REQUIRED, the server would need to provide a credential ID hint during authentication, which means the user must provide their username first.

**Challenge generation** uses `secrets.token_bytes(32)` at `backend/app/core/passkey/passkey_manager.py`. The `secrets` module is Python's CSPRNG interface, equivalent to `/dev/urandom`. The challenge must be unpredictable to prevent replay attacks. The challenge is stored in Redis with a TTL of 600 seconds (`WEBAUTHN_CHALLENGE_TTL_SECONDS = 600` in `config.py`), so it expires before an attacker could realistically capture and replay it.

**Attestation verification** at `backend/app/core/passkey/passkey_manager.py` calls `verify_registration_response` from py_webauthn. This checks that the authenticator's response was correctly signed, that the RP ID matches, that the origin matches, and that the challenge matches. The `expected_origin = self.rp_origin` check at `backend/app/core/passkey/passkey_manager.py` is critical: it ensures the registration happened from the legitimate frontend, not a phishing page on a different domain.

### Authentication Flow

Authentication follows the same challenge-response pattern. The server generates options at `backend/app/core/passkey/passkey_manager.py`, sends the challenge to the client, the client's authenticator signs the challenge with its private key, and the server verifies at `backend/app/core/passkey/passkey_manager.py`.

**Why challenge-response?** Without a fresh challenge, an attacker who intercepts one authentication response could replay it forever. The challenge ensures each authentication is unique. The authenticator signs the challenge (along with other data like the RP ID and origin) with its private key. The server verifies the signature using the stored public key. Even if the signed response is intercepted, it cannot be reused because the next authentication will have a different challenge.

**Why check origin?** The origin check (`expected_origin = self.rp_origin`) at `backend/app/core/passkey/passkey_manager.py` prevents credential phishing. If an attacker sets up a fake site at `evil-chat.com` and tricks the user into authenticating, the authenticator will include `evil-chat.com` as the origin in the signed data. When the attacker tries to forward that signed response to the real server, the origin check fails because the server expects `http://localhost:3000` (or whatever the production origin is). The authenticator binds the signature to the origin, making phishing structurally impossible.

### Clone Detection

From `backend/app/core/passkey/passkey_manager.py`:

```python
if (credential_current_sign_count != 0 and new_sign_count != 0
 and new_sign_count <= credential_current_sign_count):
 logger.error(
 "Signature counter did not increase: current=%s, new=%s. Possible cloned authenticator detected!",
 credential_current_sign_count,
 new_sign_count
 )
 raise ValueError(
 "Signature counter anomaly detected - potential cloned authenticator"
 )
```

**What cloning means.** If someone physically copies a hardware security key (or extracts the private key from a software authenticator), both the original and the clone have the same credential. Each has its own signature counter starting from the same value. When the original authenticates, its counter increments to N+1. When the clone authenticates, its counter also increments, but from N, producing N+1 (or a different value depending on when each was used). If the server sees a counter that is less than or equal to the last recorded counter, it knows two devices are using the same credential.

**Why counter must increase.** Each authentication increments the counter by at least 1. If the server stored counter=5 and the next authentication reports counter=4, something is wrong. Either the counter rolled back (impossible in a correct implementation) or a different device with an older counter value is being used.

**Edge case with counters at 0.** Some authenticators (particularly platform authenticators like Touch ID or Windows Hello) always report counter=0 and never increment it. The condition `credential_current_sign_count != 0 and new_sign_count != 0` handles this: if either counter is 0, the check is skipped entirely. This means clone detection is not available for those authenticators, but rejecting them would lock out a large portion of users. The trade-off is acceptable because platform authenticators are inherently harder to clone (they are bound to the device's secure enclave).

---

## Building the WebSocket Layer

### Connection Management

From `websocket_manager.py`:

```python
async def connect(self, websocket, user_id):
 await websocket.accept
 if user_id not in self.active_connections:
 self.active_connections[user_id] = []
 if len(self.active_connections[user_id]) >= WS_MAX_CONNECTIONS_PER_USER:
 await self._send_error(websocket, "max_connections", ...)
 await websocket.close
 return False
 self.active_connections[user_id].append(websocket)
 await presence_service.set_user_online(user_id)
 self.heartbeat_tasks[user_id] = asyncio.create_task(self._heartbeat_loop(websocket, user_id))
 await self._subscribe_to_messages(user_id)
 return True
```

**Why per-user connection lists?** A user might have the chat open on their phone and their laptop simultaneously. Each device creates its own WebSocket connection. The `active_connections` dict maps `UUID -> list[WebSocket]`, so when a message arrives for a user, it gets sent to all of their active connections. Without this, multi-device support would not work.

**Why max 5?** `WS_MAX_CONNECTIONS_PER_USER = 5` (from `config.py`). Without a limit, a malicious client could open thousands of WebSocket connections and exhaust server memory. Five is generous enough for legitimate multi-device usage (phone, tablet, laptop, desktop, maybe one more) while capping resource consumption. The specific number is configurable via environment variable.

**Why heartbeat?** WebSocket connections can silently die. A user closes their laptop lid, their WiFi drops, or a NAT gateway times out the connection. The TCP stack might not detect the dead connection for minutes or hours. The heartbeat loop at `websocket_manager.py` sends a ping every `WS_HEARTBEAT_INTERVAL` (30 seconds by default). If the send fails, it means the connection is dead, and `disconnect` cleans it up. This keeps the `active_connections` dict accurate and ensures presence status reflects reality.

### Live Query Subscription

From `websocket_manager.py`:

```python
async def _subscribe_to_messages(self, user_id):
 def message_callback(update: LiveMessageUpdate):
 asyncio.create_task(self._handle_live_message(user_id, update))

 live_id = await surreal_db.live_messages_for_user(
 user_id = str(user_id),
 callback = message_callback
 )
 self.live_query_ids[user_id] = live_id
```

**SurrealDB pushes new messages to the server, server forwards to client. No polling needed.** SurrealDB has a native live query feature. When you register a live query like `LIVE SELECT * FROM messages WHERE recipient_id = $user_id`, SurrealDB pushes every new matching record to the callback in real time. The server does not need to poll the database on a timer. When a new message is created in SurrealDB (by `message_service.store_encrypted_message`), the live query fires, `_handle_live_message` at `websocket_manager.py` picks it up, wraps it in a WebSocket message schema, and sends it to all of that user's active connections.

This is more efficient than polling because there is zero latency (the callback fires the instant the record is created) and zero wasted queries (no empty poll cycles when no messages are pending).

### Dead Connection Cleanup

The `disconnect` method at `websocket_manager.py` handles cleanup:

```python
async def disconnect(self, websocket, user_id):
 if user_id in self.active_connections:
 if websocket in self.active_connections[user_id]:
 self.active_connections[user_id].remove(websocket)

 if not self.active_connections[user_id]:
 del self.active_connections[user_id]
 await presence_service.set_user_offline(user_id)
 # Kill live query
 # Cancel heartbeat task
```

Dead connections are also detected during `send_message` at `websocket_manager.py`. If sending to a WebSocket raises an exception, that WebSocket is added to a `dead_connections` list, and each dead connection is cleaned up via `disconnect` after the send loop completes. This lazy cleanup means the system self-heals: even if a heartbeat fails to detect a dead connection, the next message send attempt will catch it.

The cleanup only sets the user offline and kills the live query when the last connection for that user is removed. If they still have another tab open, their other connection keeps working and they stay online.

---

## Building the Message Pipeline

### Server-Side Storage (Passthrough)

From `backend/app/services/message_service.py`:

```python
async def store_encrypted_message(
 self, session, sender_id, recipient_id, ciphertext, nonce, header, room_id
):
 ...
 surreal_message = {
 "sender_id": str(sender_id),
 "recipient_id": str(recipient_id),
 "room_id": room_id,
 "ciphertext": ciphertext,
 "nonce": nonce,
 "header": header,
 "sender_username": sender_user.username,
 ...
 }
 result = await surreal_db.create_message(surreal_message)
```

The server stores encrypted data without any decryption capability. The `ciphertext`, `nonce`, and `header` fields are base64-encoded strings that arrive from the client and get stored as-is. The server never sees the plaintext. The server never sees the encryption keys. The server could be fully compromised and the attacker still could not read messages, because the message keys exist only on the clients' devices in IndexedDB.

This is the correct E2E approach. Many "encrypted" chat systems encrypt on the server side, which means the server has the keys and could decrypt everything. Here, the encryption happens in `crypto-service.ts` in the browser, and the server is a dumb relay.

### Conversation Initialization

From `backend/app/services/message_service.py`:

```python
async def initialize_conversation(self, session, sender_id, recipient_id):
 # Check for existing ratchet state
 # Fetch sender's identity key
 # Fetch recipient's prekey bundle
 # Perform X3DH sender-side
 x3dh_result = initiateX3DH (frontend/src/crypto/x3dh.ts)(
 alice_identity_private_x25519 = sender_ik.private_key,
 bob_bundle = recipient_bundle,
 bob_identity_public_ed25519 = recipient_ik.public_key_ed25519
 )
 # Initialize Double Ratchet with shared key
 dr_state = double_ratchet.initialize_sender(
 shared_key = x3dh_result.shared_key,
 peer_public_key = recipient_spk_public_bytes
 )
 # Serialize and persist ratchet state to PostgreSQL
```

This is the bridge between key exchange and ongoing encryption. The method orchestrates the entire flow: check if a conversation already exists (idempotency), fetch both users' keys from PostgreSQL, perform the X3DH exchange, initialize the Double Ratchet with the resulting shared key, serialize the ratchet state, and persist it. After this method completes, `encrypt_message` and `decrypt_message` can operate using the stored ratchet state.

The check at `backend/app/services/message_service.py` is important: if a ratchet state already exists for this sender-recipient pair, the method returns it without doing anything. This prevents accidental re-initialization, which would generate a new shared secret and break the existing conversation.

---

## Security Implementation Details

### Constant-Time Comparison

From `frontend/src/crypto/primitives.ts`:

```typescript
export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
 if (a.length !== b.length) return false
 let result = 0
 for (let i = 0; i < a.length; i++) {
 result |= a[i] ^ b[i]
 }
 return result === 0
}
```

**Why XOR + OR instead of byte-by-byte comparison?** A naive comparison like `a[0] === b[0] && a[1] === b[1] && ...` short-circuits on the first mismatch. If bytes 0 through 5 match but byte 6 does not, the comparison returns `false` after checking 7 bytes. An attacker measuring the response time can determine that the first 6 bytes are correct and only byte 6 is wrong. By trying all 256 values for byte 6 and measuring which one takes slightly longer (because the comparison proceeds to byte 7), they can guess the correct value. Repeat for each byte and the entire secret is recovered.

The constant-time version XORs every byte pair and ORs the results into an accumulator. If any byte differs, at least one bit in `result` will be set. The function always processes every byte regardless of where a mismatch occurs. The execution time depends only on the array length, not on the content.

The length check at the top does leak whether the lengths are equal. This is generally acceptable because key lengths are not secret. But if length were secret, you would need to also make that comparison constant-time.

### Random Number Generation

On the Python backend, `os.urandom(AES_GCM_NONCE_SIZE)` at `frontend/src/crypto/double-ratchet.ts` reads from the operating system's cryptographically secure random number generator (CSPRNG). On Linux, this is backed by `/dev/urandom`, which draws entropy from hardware events (disk timing, network interrupts, etc.) and maintains a CSPRNG state that is computationally indistinguishable from true randomness.

On the browser frontend, the `generateRandomBytes` function at `frontend/src/crypto/primitives.ts`:

```typescript
export function generateRandomBytes(length: number): Uint8Array {
 const bytes = new Uint8Array(length)
 crypto.getRandomValues(bytes)
 return bytes
}
```

This calls the WebCrypto API's CSPRNG. Every major browser implements this using the OS CSPRNG under the hood. Chrome uses BoringSSL's CSPRNG, Firefox uses NSS, Safari uses CommonCrypto. All ultimately draw from the kernel's entropy pool.

The same function is used for nonce generation in `aesGcmEncrypt` at `frontend/src/crypto/primitives.ts`: `const nonce = generateRandomBytes(AES_GCM_NONCE_SIZE)`. It is also used for WebAuthn challenge generation on the server side via `secrets.token_bytes(WEBAUTHN_CHALLENGE_BYTES)` at `backend/app/core/passkey/passkey_manager.py`, which is Python's wrapper around `os.urandom`.

**Why CSPRNG?** Nonces, challenges, and ephemeral keys must be unpredictable. If an attacker can predict the next nonce, they can precompute the keystream for AES-GCM and decrypt messages in real time. If they can predict the next ephemeral key, they can compute the DH shared secret. If they can predict the next WebAuthn challenge, they can pre-sign a response and replay it.

**Why not Math.random?** `Math.random` uses a PRNG (pseudorandom number generator) seeded from a low-entropy source (often just the current time or a simple counter). Most JavaScript engines use xorshift128+ or a similar fast PRNG. The internal state is typically 128 bits, and it can be reconstructed by observing as few as 4-5 consecutive outputs. An attacker who knows the internal state of `Math.random` can predict every future output, which would compromise every nonce and every ephemeral key generated by the application. In 2015, researchers demonstrated recovering the full xorshift128+ state from V8's `Math.random` by observing just a few outputs. `Math.random` is fine for shuffling a deck of cards in a UI animation. It is catastrophic for cryptography.

### Key Serialization

All keys are serialized as base64url-encoded raw bytes. For example, in `frontend/src/crypto/x3dh.ts`:

```python
private_bytes = private_key.private_bytes(
 encoding = serialization.Encoding.Raw,
 format = serialization.PrivateFormat.Raw,
 encryption_algorithm = serialization.NoEncryption
)
...
return (
 bytes_to_base64url(private_bytes),
 bytes_to_base64url(public_bytes)
)
```

**Why base64url instead of hex?** Hex encoding represents each byte as two hexadecimal characters, so 32 bytes becomes 64 characters. Base64url represents every 3 bytes as 4 characters, so 32 bytes becomes approximately 43 characters. That is a 33% space saving. When you are storing thousands of keys and transmitting them over WebSocket, the savings add up.

**Why Raw format instead of PEM?** PEM format wraps the key in `-----BEGIN PRIVATE KEY-----` headers, base64 encodes a DER-encoded ASN.1 structure, and adds newlines every 64 characters. For a 32-byte X25519 private key, PEM produces roughly 120 bytes. Raw format produces exactly 32 bytes. PEM is useful when you need to identify the key algorithm from the encoding (the ASN.1 OID tells you "this is X25519"). Here, both sides already know the algorithm, so the metadata is waste.

---

## Data Flow: Complete Message Trace

Here is what happens when Alice types "Hello Bob" and it reaches Bob's screen. Every step, every file, every transformation.

**1. Alice types "Hello Bob" in Chat.tsx.** The `ChatInput` component captures the text in a form submit handler. The handler creates a temporary message ID (a random string for optimistic UI updates) and calls into the message sending logic. The plaintext exists only in the browser's JavaScript heap at this point.

**2. crypto-service.ts `encrypt("bob-uuid", "Hello Bob")`.** The `CryptoService.encrypt` method at `frontend/src/crypto/crypto-service.ts` is invoked. It first checks whether a ratchet session exists with Bob.

**3. Load ratchet state from IndexedDB.** `getRatchetState(peerId)` at `frontend/src/crypto/crypto-service.ts` checks the in-memory `Map<string, DoubleRatchetState>` first (keyed by peer ID). If the state is not in memory, it queries IndexedDB via `key-store.ts`, deserializes the stored JSON back into a `DoubleRatchetState` object (reconstructing CryptoKey objects from base64-encoded bytes), and caches it. If no state exists at all, `establishSession(peerId)` triggers the full X3DH flow: fetch Bob's prekey bundle from the server via `api.encryption.getPrekeyBundle`, perform client-side X3DH via `x3dh.ts:initiateX3DH`, and initialize the sending ratchet via `double-ratchet.ts:initializeRatchetSender`.

**4. double-ratchet.ts `encryptMessage`: advance chain key via HMAC.** At `double-ratchet.ts`, `deriveMessageKey(state.sending_chain_key)` computes two values:
 - `messageKey = HMAC-SHA-256(chainKey, "MessageKey")` - the key that will encrypt this specific message
 - `nextChainKey = HMAC-SHA-256(chainKey, "ChainKey")` - the chain key for the next message

The old `sending_chain_key` is immediately overwritten with `nextChainKey`. The `messageKey` is used once and never stored. This is the forward secrecy mechanism: after encryption, the message key cannot be recovered from the updated chain state.

**5. primitives.ts `aesGcmEncrypt` with message key.** At `double-ratchet.ts`, the 32-byte `messageKey` is imported as an AES-GCM CryptoKey. The `plaintext` bytes (`TextEncoder.encode("Hello Bob")` = 9 bytes) are encrypted. A 12-byte random nonce is generated via `crypto.getRandomValues`. The message header (DH public key, message number, previous chain length) is serialized to JSON and used as Additional Authenticated Data (AAD). AES-GCM produces the ciphertext (9 bytes of encrypted data + 16 bytes of authentication tag = 25 bytes total).

**6. Return {ciphertext, nonce, header}.** The `EncryptedMessage` object at `double-ratchet.ts` contains raw `Uint8Array` ciphertext and nonce, plus a typed `MessageHeader` object. Back in `frontend/src/crypto/crypto-service.ts`, the ciphertext and nonce are base64-encoded to strings, and the header (including any pending X3DH header for first messages) is JSON-stringified into a single string. The result is three strings: `ciphertext`, `nonce`, and `header`. All three are opaque to anyone without the message key.

**7. WebSocket sends JSON payload.** `websocket-manager.ts` calls `sendEncryptedMessage`, which constructs the outgoing message:

```json
{
 "type": "encrypted_message",
 "recipient_id": "bob-uuid",
 "room_id": "room-uuid",
 "ciphertext": "base64...",
 "nonce": "base64...",
 "header": "{\"ratchet\":{\"dh_public_key\":\"...\",\"message_number\":0,...}}",
 "temp_id": "temp-abc123"
}
```

This JSON is sent via `ws.send(JSON.stringify(message))`. If the WebSocket is not connected, the message is queued in `messageQueue` and sent when the connection is restored.

**8. websocket.py receives.** The `websocket_endpoint` at `websocket.py` calls `data = await websocket.receive_text`, parses the JSON with `json.loads(data)`, and passes the resulting dict to `websocket_service.route_message`. At this point the server has the encrypted blob. It cannot decrypt it. It does not have the message key, the chain key, or any ratchet state for Alice and Bob's conversation (in the E2E model).

**9. websocket_service.py routes to handler.** At `backend/app/services/websocket_service.py`, the message type `"encrypted_message"` dispatches to `handle_encrypted_message` at `backend/app/services/websocket_service.py`. The handler extracts `recipient_id`, `room_id`, `ciphertext`, `nonce`, and `header` from the message dict.

**10. backend/app/services/message_service.py stores in SurrealDB.** The handler calls `message_service.store_encrypted_message`, which constructs a SurrealDB document:

```python
surreal_message = {
 "sender_id": str(sender_id),
 "recipient_id": str(recipient_id),
 "room_id": room_id,
 "ciphertext": ciphertext, # still base64, still encrypted
 "nonce": nonce, # still base64
 "header": header, # still JSON string
 "sender_username": sender_user.username,
 "created_at": now.isoformat,
 "updated_at": now.isoformat,
}
```

The document is written to SurrealDB via `surreal_db.create_message(surreal_message)`. The server stores the encrypted blob verbatim. No decryption. No key access.

**11. SurrealDB live query fires.** The instant the message record is created, SurrealDB pushes a `CREATE` event to any registered live query matching `recipient_id = bob_uuid`. This is a push, not a pull. There is no polling interval. The latency from write to callback is measured in single-digit milliseconds.

**12. websocket_manager.py picks up the update.** The `_handle_live_message` callback at `websocket_manager.py` receives the `LiveMessageUpdate`. It checks that `update.action == "CREATE"` (ignoring updates and deletes). It wraps the message data in an `EncryptedMessageWS` Pydantic schema and calls `self.send_message(user_id, ws_message.model_dump(mode="json"))`.

**13. ConnectionManager sends to Bob's WebSocket(s).** At `websocket_manager.py`, the manager iterates over all of Bob's active connections (he might have the app open on his phone and laptop) and calls `websocket.send_json(message)` on each. If any send fails, that connection is added to a `dead_connections` list and cleaned up after the loop.

**14. Bob's websocket-manager.ts receives.** The `handleMessage` method at `websocket-manager.ts` parses the JSON from `event.data`. The `routeMessage` method at `websocket-manager.ts` runs through type guards. `isEncryptedMessageWS(message)` matches because the message has `type: "encrypted_message"` and the required fields. The message is dispatched to `handleWSMessage` in `message-handlers.ts`.

**15. crypto-service.ts `decrypt(alice_id, ciphertext, nonce, header)`.** The message handler calls `CryptoService.decrypt` at `frontend/src/crypto/crypto-service.ts`. The `header` string is parsed to extract the ratchet header (DH public key, message number, previous chain length) and optionally an X3DH header (if this is the first message in a new conversation).

**16. Load ratchet state from IndexedDB.** Same mechanism as step 3, but for Bob's side. If no ratchet state exists for Alice, and the message includes an X3DH header, `handleIncomingSession` at `frontend/src/crypto/crypto-service.ts` triggers:
 - Look up Alice's identity key from the X3DH header
 - Look up Bob's signed prekey private key from IndexedDB
 - Look up the consumed one-time prekey if one was used
 - Call `receiveX3DH` from `x3dh.ts` to compute the same shared secret Alice computed
 - Call `initializeRatchetReceiver` from `double-ratchet.ts` with the shared secret and Bob's signed prekey pair

**17. Check skipped keys, advance receiving chain.** `decryptMessage` at `double-ratchet.ts` runs through the three-case logic:
 - Check if this message's key was previously stored (skipped key cache hit)
 - Check if Alice's DH public key in the header differs from the last known key (DH ratchet step needed)
 - Check if the message number is ahead of the current position (skip intermediate keys)
 Then derive the message key: `messageKey = HMAC-SHA-256(receivingChainKey, "MessageKey")`.

**18. primitives.ts `aesGcmDecrypt`.** At `double-ratchet.ts`, AES-256-GCM decryption is performed. The 32-byte message key is imported as a CryptoKey. The 12-byte nonce from the message is used as the IV. The header JSON is reconstructed and used as AAD. `subtle.decrypt` verifies the 16-byte authentication tag and produces the 9 plaintext bytes. If the tag does not match (tampered message, wrong key, wrong nonce, wrong AAD), the WebCrypto API throws an `OperationError`.

**19. Return "Hello Bob".** The `Uint8Array` plaintext bytes are decoded via `new TextDecoder.decode(plaintextBytes)` at `frontend/src/crypto/crypto-service.ts`, producing the string `"Hello Bob"`. The ratchet state is serialized and saved back to IndexedDB.

**20. Chat.tsx renders plaintext.** The decrypted message is added to the message store. The reactive SolidJS component re-renders the message list. Bob sees "Hello Bob" on screen. The entire journey from Alice's keypress to Bob's screen took:
 - ~1ms for client-side encryption (HMAC + AES-GCM)
 - ~10-50ms for WebSocket round trip (depends on network)
 - ~1ms for SurrealDB write + live query fire
 - ~10-50ms for WebSocket delivery to Bob
 - ~1ms for client-side decryption
 Total: roughly 25-100ms end to end.

The plaintext "Hello Bob" existed in memory on Alice's device and Bob's device. At no other point in the pipeline, not on the WebSocket server, not in SurrealDB, not in PostgreSQL, not in Redis, did the plaintext exist. That is what end-to-end encryption means in practice.

---

## Error Handling Patterns

### Encryption Failures

When encryption fails (corrupted ratchet state, invalid key, etc.), an `EncryptionError` is raised at `backend/app/services/message_service.py`. The exception hierarchy in `exceptions.py` derives from `AppException`. The exception handler returns the error to the client via the WebSocket error message type. The message is never stored, because the encryption failed before the store call.

### Database Transaction Failures

`IntegrityError` is caught in every service method that writes to the database. For example, at `backend/app/services/message_service.py`:

```python
except IntegrityError as e:
 await session.rollback
 raise DatabaseError("Failed to initialize conversation") from e
```

The pattern is consistent: catch the SQLAlchemy integrity error, roll back the session to a clean state, then raise a custom `DatabaseError`. This ensures the database is never left in a partially committed state. The `from e` chain preserves the original exception for logging.

### WebSocket Disconnection

When a WebSocket disconnects (user closes the tab, network drops), `WebSocketDisconnect` is caught at `websocket.py`. The `finally` block at `websocket.py` always runs `connection_manager.disconnect(websocket, user_uuid)`, which:
- Removes the WebSocket from the connection pool
- If it was the last connection for that user: kills the SurrealDB live query, cancels the heartbeat task, and sets presence to offline via Redis
- If other connections remain: just removes this one and logs the remaining count

---

## Testing Strategy

### Unit Tests

**Test X3DH key agreement.** Generate identity keys for Alice and Bob. Generate a signed prekey for Bob. Generate an OPK for Bob. Assemble Bob's prekey bundle. Perform sender-side X3DH as Alice via `initiateX3DH (frontend/src/crypto/x3dh.ts)`. Perform receiver-side X3DH as Bob via `receiveX3DH (frontend/src/crypto/x3dh.ts)`, passing Alice's ephemeral public key and identity key from the sender result. Assert that `alice_result.shared_key == bob_result.shared_key`. This verifies the commutative DH math. Also assert that `alice_result.associated_data == bob_result.associated_data`, confirming both sides compute the same AAD.

Test the OPK-absent case separately: set `bob_bundle.one_time_prekey = None`, pass `bob_one_time_prekey_private = None` on the receiver side. Verify the shared keys still match (they will, because both sides fall back to the 3-DH variant).

Test signature verification failure: corrupt one byte of the SPK signature, call `perform_x3dh_sender`, assert it raises `ValueError("Invalid signed prekey signature")`.

**Test Double Ratchet round-trip.** Initialize sender and receiver with the shared key from X3DH. Encrypt "message 1" on the sender side. Decrypt on the receiver side. Assert plaintext matches. Then encrypt "message 2" on the receiver side and decrypt on the sender side. This tests a full ratchet cycle where the DH ratchet advances twice (once for each direction change).

Continue with a longer sequence: sender sends 5 messages in a row, receiver decrypts all 5 (this tests the symmetric chain without DH ratcheting), then receiver sends 3 messages back, sender decrypts all 3. Verify every plaintext.

**Test out-of-order delivery.** Encrypt messages 0, 1, 2, 3, 4 on the sender. Deliver message 4 first. The receiver should store skipped keys for messages 0, 1, 2, 3, decrypt message 4 successfully, then decrypt messages 2, 0, 3, 1 in any order using the stored skipped keys. Verify all five plaintexts are correct. Verify the skipped key cache is empty after all messages are decrypted (each key is consumed on use).

**Test max skip enforcement.** Construct a `DoubleRatchet(max_skip=5)`. Encrypt messages 0 through 20 on the sender. Attempt to deliver message 20 first (requiring 20 skips). Assert the receiver raises `ValueError("Cannot skip 20 messages (MAX_SKIP=5)")`. Then deliver message 4 (requiring 4 skips). Assert it succeeds. This confirms the limit is enforced and legitimate small gaps still work.

**Test cache eviction.** Construct a `DoubleRatchet(max_skip=100, max_cache=10)`. Skip 10 messages to fill the cache. Skip 5 more. Assert that the cache now has 10 entries (5 old ones were evicted to make room). Attempt to decrypt one of the evicted messages. Assert decryption fails (the key is gone).

**Test WebAuthn flows.** Mock the authenticator response objects as dictionaries conforming to the WebAuthn spec. Call `passkey_manager.generate_registration_options` with a test user ID and username. Verify the returned options include the correct RP ID, RP name, and challenge. Call `passkey_manager.verify_registration` with the mock response and the challenge. Verify the returned `VerifiedRegistration` has the correct credential ID and sign count.

For authentication, call `passkey_manager.generate_authentication_options`. Feed the challenge into a mock authentication response. Call `passkey_manager.verify_authentication` with the stored credential public key and a current sign count. Verify the returned `VerifiedAuthentication` has an incremented sign count.

For clone detection, call `verify_authentication` with `credential_current_sign_count=5` and a mock response where `new_sign_count=3`. Assert it raises `ValueError("Signature counter anomaly detected")`.

### Integration Tests

**Full message flow (frontend).** Stand up two clean clients in `vitest`, run `generateIdentityKeyPair` / `generateSignedPreKey` / `generateOneTimePreKeys` for each, hand Alice Bob's bundle, run `initiateX3DH` and `initializeRatchetSender`, encrypt a message, then on Bob's side run `receiveX3DH` + `initializeRatchetReceiver` and `decryptMessage`. Assert the plaintext matches. The existing `frontend/src/crypto/x3dh.test.ts` and `frontend/src/crypto/double-ratchet.test.ts` already cover this end-to-end.

**WebSocket lifecycle.** Spin up the FastAPI test app, register two users via the auth flow (which sets a session cookie), open two WebSocket connections carrying the cookies, and exercise the full message round-trip. The cookie-authenticated WebSocket is the only auth path — there is no `?user_id=` query string anymore.

**Database rollback on failure.** Create an async session. Start an operation that will fail (for example, inserting an `IdentityKey` row whose `user_id` doesn't exist). Assert that the session rolls back cleanly and raises `DatabaseError`. Verify that no partial data was committed by querying the table afterward.

**Key rotation.** Generate a fresh signed prekey on the client (`generateSignedPreKey`), call `uploadKeys` again with it, then re-fetch the bundle as a peer. Verify the bundle contains the new SPK and that its signature validates against the user's Ed25519 identity key. Confirm that the previously-active SPK row is now `is_active = False` in PostgreSQL.

**OPK exhaustion.** Upload a user with 2 OPKs. Fetch their prekey bundle twice (consuming both, marking them `is_used = True`). Fetch a third time and verify the bundle returns with `one_time_prekey = None`. Verify X3DH still succeeds without the OPK (the 3-DH fallback).

---

## Common Implementation Pitfalls

### Pitfall 1: Nonce Reuse in AES-GCM

**Symptom:** Decryption succeeds but authentication tag verification fails intermittently (or worse, decryption succeeds and you do not notice the security break).

**Cause:** Reusing the same nonce with the same key completely breaks GCM's security. AES-GCM uses the nonce to generate a unique keystream via CTR mode. If two messages share the same nonce and key, XORing the two ciphertexts cancels out the keystream and produces the XOR of the two plaintexts. An attacker can then use frequency analysis or known-plaintext attacks to recover both messages. Additionally, the authentication tag becomes forgeable.

**Fix:** Always use `os.urandom(12)` for a fresh nonce, as done at `frontend/src/crypto/double-ratchet.ts`. Since each message key is derived from a unique chain key position, nonce reuse across different message keys is not a concern. The risk would only arise if the same message key were used twice, which the chain advancement prevents.

### Pitfall 2: Not Verifying Signed Prekey

**Symptom:** X3DH succeeds but communication can be intercepted by a man-in-the-middle.

**Cause:** Skipping signature verification allows an attacker to substitute their own SPK into Bob's prekey bundle. Alice computes a shared secret with the attacker. The attacker independently computes a shared secret with Bob using Bob's real SPK. The attacker can now read and modify all messages.

**Fix:** Always verify before exchange, as done at `frontend/src/crypto/x3dh.ts`:

```python
if not self.verify_signed_prekey(bob_bundle.signed_prekey,
 bob_bundle.signed_prekey_signature,
 bob_identity_public_ed25519):
 raise ValueError("Invalid signed prekey signature")
```

### Pitfall 3: Storing Private Keys on Server

**Symptom:** Server compromise exposes all conversations.

**Cause:** If private key material is accessible to the server, anyone who compromises the server (SQL injection, SSH access, backup leak) can decrypt every message ever sent.

**Fix:** Client-side key generation and IndexedDB storage. The server only stores public keys. Look at `backend/app/services/prekey_service.py`: the `store_client_keys` method receives only public keys from the client. The `private_key` fields on `IdentityKey` and `SignedPrekey` models are set to empty strings `""` when storing client-uploaded keys. Private keys live exclusively in the browser's IndexedDB, which is sandboxed per origin.

### Pitfall 4: Non-Constant-Time Comparison

**Symptom:** Timing side channel leaks key material byte by byte.

**Cause:** Using `===` or `==` for byte array comparison in JavaScript short-circuits on the first mismatch. An attacker who can measure response times with sufficient precision (microsecond resolution is achievable over a network) can determine how many leading bytes are correct and brute-force the rest.

**Fix:** XOR-based comparison as in `frontend/src/crypto/primitives.ts`:

```typescript
export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
 if (a.length !== b.length) return false
 let result = 0
 for (let i = 0; i < a.length; i++) {
 result |= a[i] ^ b[i]
 }
 return result === 0
}
```

---

## Code Organization Principles

The codebase follows a strict layering that separates concerns and minimizes the blast radius of bugs.

- **Encryption logic in `frontend/src/crypto/`** (never in the API layer). The `frontend/src/crypto/x3dh.ts` and `frontend/src/crypto/double-ratchet.ts` files have zero knowledge of HTTP, WebSocket, or databases. They take bytes in and return bytes out. `X3DHManager` does not import SQLModel. `DoubleRatchet` does not import FastAPI. This makes them independently testable: you can instantiate `X3DHManager` in a test file, call `generate_identity_keypair_x25519`, and verify the output without setting up a database, a Redis connection, or a web server. It also makes them reusable: if you wanted to use the same X3DH implementation in a CLI tool or a different server framework, you could import `frontend/src/crypto/` without pulling in any web dependencies.

- **Database operations in `services/`** (never in core). The `prekey_service.py`, `message_service.py`, and `auth_service.py` files handle all SQLModel queries and SurrealDB operations. They receive an `AsyncSession` as a parameter (dependency injection) and call into `frontend/src/crypto/` for crypto operations. The crypto layer never sees a session object, and the service layer never calls OpenSSL directly. This means a database schema change only affects service files and models, not the encryption logic.

- **Pydantic schemas for ALL API boundaries.** Every WebSocket message type has a corresponding schema in `schemas/websocket.py` (e.g., `EncryptedMessageWS`, `TypingIndicatorWS`, `ErrorMessageWS`). Every HTTP request/response has a schema in `schemas/auth.py`, `schemas/rooms.py`, etc. This provides runtime validation: if a client sends a malformed payload (missing fields, wrong types, oversized strings), Pydantic rejects it before the data reaches service logic. For example, `ENCRYPTED_CONTENT_MAX_LENGTH = 50000` in `config.py` caps the ciphertext field length, preventing a client from sending a 10GB ciphertext that would consume server memory.

- **Module-level singletons for stateless managers.** At the bottom of `backend/app/core/websocket_manager.py`: `connection_manager = ConnectionManager`. At the bottom of `backend/app/core/redis_manager.py` and `backend/app/core/surreal_manager.py`: `redis_manager` and `surreal_db`. The X3DH and Double Ratchet implementations live in the browser as plain TypeScript modules with exported functions, so there's no equivalent server-side singleton for them. The Python singletons either manage shared connection pools or are stateless wrappers; they're safe to share across the process because (a) stateless managers have no mutable state, so concurrent async tasks cannot interfere with each other, and (b) `connection_manager.active_connections` is touched only inside the single event loop.

- **Async all the way through (no blocking I/O).** Every database query uses `await session.execute(...)`. Every WebSocket operation uses `await websocket.send_json(...)`. Every Redis call uses async methods. Every SurrealDB call uses async methods. The only synchronous operations are the CPU-bound cryptographic computations (HMAC, HKDF, AES-GCM, X25519 DH exchange), which complete in microseconds and do not benefit from async. If a crypto operation ever became slow (e.g., Argon2 password hashing taking 500ms), it would need to be offloaded to a thread pool via `asyncio.to_thread` to avoid blocking the event loop. But the operations used here are all sub-millisecond.

- **Custom exception hierarchy in `exceptions.py`.** Every error type has its own exception class (`EncryptionError`, `DecryptionError`, `KeyExchangeError`, `DatabaseError`, `UserNotFoundError`, etc.), all inheriting from `AppException`. This allows `exception_handlers.py` to map each exception type to an appropriate HTTP status code and error response. A `UserNotFoundError` returns 404. An `EncryptionError` returns 500. A `ChallengeExpiredError` returns 401. Without the hierarchy, every error would be a generic 500, and the client would have no idea what went wrong.

- **Frontend mirrors the backend structure.** The frontend's `crypto/` directory parallels the backend's `frontend/src/crypto/`. `primitives.ts` provides the same low-level operations as Python's `cryptography` library. `x3dh.ts` parallels `frontend/src/crypto/x3dh.ts`. `double-ratchet.ts` parallels `frontend/src/crypto/double-ratchet.ts`. `crypto-service.ts` parallels `message_service.py` (the orchestration layer). This symmetry makes it easier to trace a bug: if decryption fails, you compare the frontend and backend implementations step by step, checking that the same constants, the same byte orderings, and the same HKDF parameters are used on both sides.

---

## Dependencies and Why

### Backend

- **cryptography:** The Python Cryptographic Authority's library. It wraps OpenSSL for performance-critical operations (AES-GCM, HKDF) and provides native implementations for curve operations (X25519, Ed25519). The library is audited, has a dedicated security response team, and follows a responsible disclosure process. It is the standard choice for Python crypto when you need low-level primitives. Alternatives like PyCryptodome exist but have a smaller maintainer base, less rigorous audit history, and a different API style (PyCryptodome requires more manual buffer management). The `cryptography` library also has the advantage of separating "hazmat" (hazardous materials) primitives from high-level recipes, which makes it explicit when you are doing something that requires careful handling.

- **py_webauthn:** Implements the WebAuthn/FIDO2 server-side protocol. Handles the complex ASN.1 parsing of attestation objects, CBOR decoding of authenticator data, signature verification across multiple algorithm families (ES256, RS256, EdDSA), and challenge lifecycle management. The WebAuthn specification is over 200 pages. Writing a compliant implementation from scratch would take months and invite subtle bugs in the CBOR parsing alone. py_webauthn also provides convenient helpers like `bytes_to_base64url` and `base64url_to_bytes` that we use throughout the encryption code.

- **sqlmodel:** Combines SQLAlchemy's query builder with Pydantic's validation. You define a model once (like `User` or `IdentityKey`) and get both a database table schema and a Pydantic serialization schema. The `AsyncSession` support via `sqlmodel.ext.asyncio.session` integrates cleanly with FastAPI's async request handlers. The alternative would be using raw SQLAlchemy models plus separate Pydantic schemas, which doubles the model definitions and introduces synchronization risk (changing a column in the SQLAlchemy model but forgetting to update the Pydantic schema).

- **surrealdb:** The Python client for SurrealDB's WebSocket protocol. The key feature is live query support: `LIVE SELECT * FROM messages WHERE recipient_id = $user_id` creates a persistent subscription that pushes new matching records to a callback. This eliminates the need for a separate pub/sub system (like Redis Pub/Sub or RabbitMQ) for real-time message delivery. SurrealDB serves as both the message store and the real-time event bus.

- **orjson:** A Rust-backed JSON serializer that is 3-10x faster than the standard `json` module. When the server is serializing hundreds of WebSocket messages per second (each containing base64-encoded ciphertext and headers), the difference is measurable in CPU utilization. orjson also handles `datetime`, `UUID`, and `bytes` natively without custom serializers, reducing boilerplate code. It produces the same JSON output as the standard library, so it is a drop-in replacement.

### Frontend

- **WebCrypto API (built-in):** Browser-native cryptographic primitives. No npm dependencies for crypto means zero supply chain risk for the most security-critical code in the application. A malicious update to an npm crypto package could steal private keys or weaken encryption. With WebCrypto, the crypto implementation is part of the browser itself, updated through the browser's own security process. `subtle.generateKey`, `subtle.deriveBits`, `subtle.encrypt`, `subtle.decrypt`, `subtle.sign`, and `subtle.verify` cover every operation needed for X25519, Ed25519, AES-GCM, HKDF, and HMAC. The implementations run in native C/C++/Rust code, which is both faster and more resistant to timing attacks than JavaScript implementations. WebCrypto also enforces key usage restrictions at the API level (a key imported for "encrypt" cannot be used for "decrypt"), providing defense in depth.

- **nanostores:** A minimal state management library under 1KB gzipped. For a chat application, the state management needs are straightforward: "who is online," "what messages are in this room," "is the user typing," "which room is selected." Nanostores provides reactive `atom` (single value) and `computed` (derived value) stores that integrate with SolidJS's reactive system. The `$connectionStatus`, `$isConnected`, and `$reconnectAttempts` atoms in `websocket-manager.ts` demonstrate the pattern. Unlike Redux (which requires actions, reducers, and middleware for async operations), nanostores is just get/set/subscribe. The simplicity is the point: fewer abstractions means fewer places for bugs to hide.

- **@tanstack/solid-query:** Manages server state (data fetched from REST APIs) separately from client state (UI interactions, WebSocket events). Handles caching (do not re-fetch the room list if it was fetched 30 seconds ago), background refetching (update the room list when the tab regains focus), stale-while-revalidate (show the cached data immediately, fetch fresh data in the background), and error/loading/success state transitions. Without it, every component that needs server data would manually manage `isLoading`, `error`, and `data` state, implement its own cache invalidation logic, and handle race conditions between concurrent fetches. TanStack Query absorbs all that complexity into a declarative `createQuery` call.
