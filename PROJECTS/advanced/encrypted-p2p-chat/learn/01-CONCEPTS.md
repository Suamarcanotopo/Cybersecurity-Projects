# Security Concepts

This document covers the cryptographic and authentication foundations of
the encrypted P2P chat application. Every concept here maps directly to
code in the repository. If you can read and understand this document, you
will know exactly what happens to a message from the moment a user types
it to the moment it appears on the recipient's screen, and why every
step exists.


## End-to-End Encryption

### What It Is

End-to-end encryption (E2EE) is a communication model where only the
two endpoints of a conversation can read the messages exchanged between
them. The defining property is that the server acts as a blind relay: it
stores and forwards encrypted blobs, but it has no key material that
would allow it to decrypt those blobs. The encryption happens on the
sender's device, the decryption happens on the recipient's device, and
at no point between those two devices does the plaintext exist.

This is different from transport encryption (TLS/HTTPS), which encrypts
the link between your device and the server, and between the server and
the other device, but allows the server itself to read everything. With
transport encryption, the server is a trusted intermediary. With E2EE,
the server is an untrusted courier.

The distinction matters because trust is a vulnerability. If the server
can read your messages, then anyone who compromises the server can also
read your messages. That includes attackers who breach the server, rogue
employees, and government agencies with legal authority to compel the
server operator to produce data.

### Why It Matters

The history of messaging security is a history of servers being
compromised, coerced, or caught lying about their access to user data.

**2013: Edward Snowden and the NSA PRISM program.** Snowden leaked
classified NSA documents showing that major technology companies
including Google, Microsoft, Yahoo, Facebook, Apple, and others had
provided the NSA with direct server-side access to user communications
under the PRISM surveillance program. Because these services used
transport encryption rather than E2E encryption, the companies held
decryption keys on their servers and could comply with government
requests (or be compelled to comply through FISA court orders). The
server had access, so the government got access. This was the single
largest catalyst for the adoption of end-to-end encryption in consumer
products.

**2019: Jeff Bezos WhatsApp hack.** In January 2020, forensic analysis
by FTI Consulting concluded that Amazon CEO Jeff Bezos's iPhone was
compromised via a malicious video file sent through WhatsApp from Saudi
Crown Prince Mohammed bin Salman's account. While WhatsApp's Signal
Protocol E2E encryption protected the message content in transit, the
attack targeted the endpoint device itself with spyware (attributed to
NSO Group's Pegasus). This case is instructive because it shows both
the strength and the boundary of E2E encryption: it protects messages
between devices, but if the device itself is compromised, the attacker
reads the plaintext after decryption. E2E encryption defends against
network and server compromise, not endpoint compromise.

**2020: Zoom E2E encryption scandal.** Zoom Video Communications
marketed their product as providing "end-to-end encryption" for video
calls. Investigation by The Intercept (March 2020) and the Citizen Lab
at University of Toronto revealed that Zoom held the encryption keys on
their servers. Calls were encrypted with AES-128 in ECB mode (a weak
cipher mode that leaks patterns) between the client and Zoom's server,
but Zoom's infrastructure could decrypt all call content. The FTC
settlement in November 2020 required Zoom to implement actual security
measures and prohibited them from misrepresenting their encryption
practices. This case demonstrates that the word "encrypted" without the
qualifier "end-to-end" is meaningless for privacy.

**2021: ProtonMail logging controversy.** ProtonMail, a Swiss encrypted
email provider that markets itself on privacy, was compelled by a Swiss
court order (requested via Europol on behalf of French authorities) to
log the IP address and browser fingerprint of a French climate activist.
While ProtonMail's E2E encryption meant they could not read email
content, they were compelled to collect metadata. The server could not
read messages, but it could identify who was sending them. This case
shows that E2E encryption solves the content problem but does not
automatically solve the metadata problem.

The pattern is consistent: any server that CAN read your messages WILL
eventually be compelled to, whether by government subpoena, by
attackers who breach the infrastructure, or by insiders who abuse their
access. The only reliable defense is to make it architecturally
impossible for the server to read the data in the first place.

### How It Works (in this project)

```
Alice's Device Server Bob's Device
+----------------+ +----------------+ +----------------+
| Plaintext | | | | |
| "Hello Bob" | | Encrypted | | Plaintext |
| | | ---> | blob only | ---> | "Hello Bob" |
| v | | No keys | | ^ |
| AES-256-GCM | | No access | | AES-256-GCM |
| encrypt | | No decrypt | | decrypt |
+----------------+ +----------------+ +----------------+

Keys derived from Server stores Keys derived from
Double Ratchet on ciphertext, nonce, Double Ratchet on
Alice's device and header verbatim Bob's device
```

On the server side, `backend/app/services/message_service.py` implements the
`store_encrypted_message` method. Look at the docstring :
`"Stores client-encrypted message in SurrealDB (pass-through, no server encryption)"`.
The function receives `ciphertext`, `nonce`, and `header` as strings
from the client, and stores them directly in SurrealDB
without any decryption or re-encryption step. The server is a
passthrough. It writes what it receives and reads what it wrote. At no
point does it import any cryptographic key or call any decryption
function on these message parameters.

On the client side, `frontend/src/crypto/crypto-service.ts` implements the
`encrypt` method. The client calls `encryptMessage` from
`double-ratchet.ts` , receives ciphertext and nonce, then
sends these as base64-encoded strings to the server. The plaintext
never leaves the client's process. The actual symmetric encryption
happens in `frontend/src/crypto/primitives.ts` using the WebCrypto API's AES-GCM
implementation, which runs in the browser's native cryptographic module
rather than in JavaScript. This means the plaintext is never even
accessible to JavaScript debugging tools during the encryption
operation itself.


## The Signal Protocol

### What It Is

The Signal Protocol is a cryptographic ratcheting protocol originally
developed by Trevor Perrin and Moxie Marlinspike at Open Whisper Systems
(now the Signal Foundation). It was designed to provide end-to-end
encryption for instant messaging with strong forward secrecy and
post-compromise security properties.

The protocol was first deployed in the TextSecure application (the
predecessor to Signal) and was formally described in a series of
technical specifications published at signal.org/docs. It was
independently analyzed and formally verified in academic papers,
including "A Formal Security Analysis of the Signal Messaging Protocol"
by Cohn-Gordon et al. at IEEE EuroS&P 2017, which proved that the
protocol meets its claimed security properties under standard
cryptographic assumptions.

The Signal Protocol is now deployed at massive scale. WhatsApp completed
its rollout of Signal Protocol encryption to all users in April 2016,
covering over 1 billion users at the time (now over 2 billion). Google
Messages adopted the Signal Protocol for RCS messaging. Facebook
Messenger offered it as an optional "Secret Conversations" mode. Skype
implemented it as "Private Conversations." The protocol's design has
been influential enough that it is effectively the industry standard for
secure messaging.

### The Two Core Components

The Signal Protocol combines two distinct cryptographic mechanisms, each
solving a different problem:

```
Signal Protocol = X3DH (initial handshake) + Double Ratchet (ongoing encryption)

X3DH: "How do Alice and Bob agree on a shared secret
 when Bob might be offline?"

 Solves the ASYNCHRONOUS key agreement problem.
 Bob uploads prekey bundles to the server ahead of time.
 Alice can start a conversation using Bob's prekeys
 without Bob being online.

Double Ratchet: "Once they share a secret, how do they
 encrypt each message with a UNIQUE key
 that can never be recovered?"

 Solves the FORWARD SECRECY and POST-COMPROMISE
 SECURITY problem. Every message gets its own
 ephemeral encryption key. Compromising one key
 does not reveal past or future messages.
```

X3DH runs once at the start of a conversation. The Double Ratchet runs
continuously for every message after that. The output of X3DH (a shared
secret) is the input to the Double Ratchet (the initial root key).


## X3DH (Extended Triple Diffie-Hellman)

### What It Is

Standard Diffie-Hellman key exchange requires both parties to be online
at the same time. Alice generates a value, sends it to Bob, Bob
generates a value, sends it back to Alice, and they both compute the
shared secret. This works fine for a phone call or a live connection,
but it does not work for asynchronous messaging. If Alice wants to send
Bob a message at 3 AM while Bob's phone is off, standard DH cannot
proceed because Bob is not there to generate and send his half.

X3DH solves this by having Bob pre-generate a set of key material and
upload it to the server before going offline. This pre-generated material
is called a "prekey bundle." When Alice wants to start a conversation,
she downloads Bob's prekey bundle from the server and uses it to compute
a shared secret without Bob's participation. When Bob comes back online,
he can compute the same shared secret from the information Alice sends
him, because the mathematics of Diffie-Hellman allow both parties to
independently arrive at the same result.

The "Extended Triple" in X3DH refers to the fact that the protocol
performs three or four separate Diffie-Hellman operations (not just one)
to achieve stronger security properties than a single DH exchange would
provide.

### Key Types

X3DH uses four types of keys. Each has a different lifetime and purpose.
Understanding why four types exist (instead of just one) is essential to
understanding the security model.

**Identity Key (IK) -- Long-term, generated once per user**

The identity key is a permanent keypair that represents the user's
cryptographic identity. It is generated once and kept for the lifetime
of the account. This project generates two identity keypairs per user:

- An X25519 keypair for Diffie-Hellman operations
 (ref: `frontend/src/crypto/x3dh.ts`)
- An Ed25519 keypair for digital signatures
 (ref: `frontend/src/crypto/x3dh.ts`)

The X25519 keypair participates directly in the DH calculations. The
Ed25519 keypair signs the signed prekey to prove it belongs to the same
identity. These are separate curves because X25519 is a Diffie-Hellman
function (it computes shared secrets) and Ed25519 is a signature scheme
(it signs and verifies data). They cannot be interchanged. The private
keys are stored in the database (server-side) or in IndexedDB
(client-side), and they never change unless the user explicitly resets
their identity.

**Signed Prekey (SPK) -- Medium-term, rotated every 48 hours**

The signed prekey is an X25519 keypair that rotates periodically. In
this project, rotation happens every 48 hours as configured at
`config.py` (`SIGNED_PREKEY_ROTATION_HOURS=48`).

When a new SPK is generated (`frontend/src/crypto/x3dh.ts`), the public
key is signed using the Ed25519 identity key :
`signature = identity_private.sign(spk_public_bytes)`. This signature
proves that the SPK was created by the holder of the identity key. When
Alice downloads Bob's prekey bundle, she verifies this signature before
using the SPK, which prevents a man-in-the-middle from substituting
their own SPK.

The rotation period is a tradeoff. Shorter rotation provides better
forward secrecy (because old SPKs are deleted, and any DH secrets
computed with them become unrecoverable). Longer rotation means fewer
key management operations and less complexity. The 48-hour window used
here is consistent with Signal's recommendation.

Old signed prekeys are kept around (with `is_active = False`) so
messages-in-flight that were encrypted against the previous SPK can
still complete their initial X3DH on the receiver. There is no
automated reaper in this codebase; pruning very old inactive SPKs is a
suggested extension in `04-CHALLENGES.md`.

**One-Time Prekey (OPK) -- Single use, consumed and deleted**

One-time prekeys are X25519 keypairs that are used exactly once and then
discarded. They are generated in batches
(ref: `frontend/src/crypto/x3dh.ts` for generation,
`backend/app/services/prekey_service.py` for batch replenishment) and uploaded to the
server.

When Alice initiates a conversation with Bob, the server gives Alice one
of Bob's unused OPKs and marks it as consumed
(`backend/app/services/prekey_service.py`). This OPK participates in the fourth DH
operation (DH4) of the X3DH handshake. Because the OPK is used only
once and then deleted, it provides an additional layer of forward
secrecy specifically for the initial message of a conversation.

If Bob has no unused OPKs remaining (they have all been consumed by
other users initiating conversations), X3DH falls back to three DH
operations instead of four. The protocol still works, but the initial
message has slightly weaker forward secrecy because the fourth DH
operation is skipped. The system generates 100 OPKs initially
(`config.py`, `DEFAULT_ONE_TIME_PREKEY_COUNT=100`) and replenishes
them when the supply drops below half.

**Ephemeral Key (EK) -- Generated per session, never stored**

The ephemeral key is a fresh X25519 keypair generated by Alice (the
sender) at the moment she initiates a conversation. It is used in DH2,
DH3, and DH4 of the X3DH handshake. It is never stored on disk; it
exists only in memory for the duration of the key exchange computation.

In the code, it is generated at `frontend/src/crypto/x3dh.ts`:

```python
alice_ek_private = X25519PrivateKey.generate
alice_ek_public = alice_ek_private.public_key
```

After the shared secret is computed, Alice sends the ephemeral public
key to Bob (so Bob can perform the same DH operations on his side), and
the ephemeral private key is discarded. Because the private component is
never persisted, even if Alice's device is later compromised, the
attacker cannot recover the ephemeral private key and therefore cannot
recompute the initial shared secret.

### The Math

X3DH performs four Diffie-Hellman operations between different
combinations of keys. Each operation produces a 32-byte shared secret.
The four secrets are concatenated and fed into HKDF to produce the final
shared key.

```
Alice (sender) has: Bob (receiver) has:
 IK_A (identity private key) IK_B (identity public key)
 EK_A (ephemeral, just generated) SPK_B (signed prekey public)
 OPK_B (one-time prekey public)

DH Operations (each produces 32 bytes):

 DH1 = X25519(IK_A_private, SPK_B_public)
 Alice's identity x Bob's signed prekey

 DH2 = X25519(EK_A_private, IK_B_public)
 Alice's ephemeral x Bob's identity

 DH3 = X25519(EK_A_private, SPK_B_public)
 Alice's ephemeral x Bob's signed prekey

 DH4 = X25519(EK_A_private, OPK_B_public) [optional]
 Alice's ephemeral x Bob's one-time prekey

Key Material Derivation:

 input = 0xFF * 32 || DH1 || DH2 || DH3 || DH4
 salt = 0x00 * 32
 info = "X3DH"
 SK = HKDF-SHA256(salt, input, info, length=32)
```

In the codebase, the sender side is at `frontend/src/crypto/x3dh.ts`:

- Line 241: `dh1 = alice_ik_private.exchange(bob_spk_public)` -- DH1
- Line 242: `dh2 = alice_ek_private.exchange(bob_ik_public)` -- DH2
- Line 243: `dh3 = alice_ek_private.exchange(bob_spk_public)` -- DH3
- Line 251: `dh4 = alice_ek_private.exchange(bob_opk_public)` -- DH4 (if OPK available)
- Line 252: `key_material = dh1 + dh2 + dh3 + dh4` -- concatenation
- Lines 257-264: HKDF derivation with `0xFF * 32` prefix and `b'X3DH'` info string

The receiver side at `frontend/src/crypto/x3dh.ts` performs the same
operations but with the roles reversed. DH1 becomes
`bob_spk_private.exchange(alice_ik_public)` , because Bob has
the SPK private key and Alice's IK public key. The property of
Diffie-Hellman guarantees that `X25519(a_priv, B_pub)` produces the
same result as `X25519(b_priv, A_pub)`, so both sides compute identical
shared secrets.

The `0xFF * 32` prefix prepended (`f = b'\xff' * X25519_KEY_SIZE`)
is a fixed padding specified by the X3DH standard. It ensures the HKDF
input is at least 32 bytes long even in edge cases and provides domain
separation from other uses of the same keys.

### Why Four DH Operations?

Each DH operation provides a specific security property. If any single
operation were removed, a specific class of attack would become possible.

**DH1: IK_A x SPK_B -- Authenticates Alice to Bob**

This operation uses Alice's long-term identity key. Only Alice (the
holder of IK_A_private) could have produced this DH output with
SPK_B_public. When Bob computes the same value using SPK_B_private and
IK_A_public, he has cryptographic proof that the message came from
Alice. Without DH1, anyone who knows Bob's public SPK could impersonate
any sender.

**DH2: EK_A x IK_B -- Authenticates Bob to Alice**

This operation uses Bob's long-term identity key. Only Bob (the holder
of IK_B_private) could reproduce this DH output. This ensures Alice is
actually talking to Bob, not to an impersonator who uploaded their own
prekey bundle to the server. Without DH2, a malicious server could
substitute its own keys for Bob's and perform a man-in-the-middle attack.

**DH3: EK_A x SPK_B -- Provides forward secrecy**

This operation uses Alice's ephemeral key (generated fresh, never stored)
and Bob's signed prekey (rotated every 48 hours). Because EK_A_private
is discarded immediately and SPK_B_private is eventually deleted during
rotation, this DH output becomes unrecoverable after both keys are gone.
Even if both Alice and Bob's identity keys are later compromised, past
session keys derived partly from DH3 cannot be recomputed. This is the
core forward secrecy guarantee.

**DH4: EK_A x OPK_B -- Additional forward secrecy for initial messages**

This operation uses Bob's one-time prekey, which is consumed and deleted
immediately after use. It provides forward secrecy specifically for the
first message in a conversation. Without DH4, if an attacker compromised
Bob's SPK_private (which exists for up to 48 hours), they could
retroactively decrypt initial messages sent during that window. DH4
ensures that even a compromised SPK is insufficient, because OPK_private
was deleted the moment it was used.

DH4 also prevents replay attacks on the initial handshake. Because the
OPK is single-use, an attacker who records Alice's initial message
cannot replay it later: Bob has already consumed the OPK, so the server
will not provide the same one again, and Bob's side will not have the
OPK private key available for a replayed handshake.

### Prekey Bundle Verification

Before performing any DH operations, Alice must verify that Bob's signed
prekey actually belongs to Bob. A malicious server could substitute its
own SPK and intercept communications.

The verification happens at `frontend/src/crypto/x3dh.ts` inside
`perform_x3dh_sender`:

```python
if not self.verify_signed_prekey(bob_bundle.signed_prekey,
 bob_bundle.signed_prekey_signature,
 bob_identity_public_ed25519):
 raise ValueError("Invalid signed prekey signature")
```

The `verify_signed_prekey` method at `frontend/src/crypto/x3dh.ts` uses
Ed25519 signature verification. It decodes the SPK public key bytes, the
signature bytes, and the Ed25519 identity public key bytes, then calls
`identity_public.verify(signature_bytes, spk_public_bytes)` .
Ed25519 verification either succeeds or raises `InvalidSignature`. If
verification fails, the entire X3DH handshake is aborted.

This verification is critical. Without it, a server-side attacker could
replace Bob's SPK with one they control, perform DH operations using
their own private key, and transparently proxy messages between Alice
and Bob while reading everything. The Ed25519 signature binds the SPK
to Bob's identity key, making substitution detectable.

Note that this only works if Alice has Bob's authentic identity public
key. In practice, identity key verification is done through "safety
numbers" or "key verification" -- a separate out-of-band process where
Alice and Bob compare fingerprints of each other's identity keys in
person or through a trusted secondary channel.


## Double Ratchet Algorithm

### What It Is

The Double Ratchet is an algorithm for managing encryption keys in an
ongoing conversation. It was developed by Trevor Perrin and Moxie
Marlinspike as part of the Signal Protocol, building on earlier work
from the Off-the-Record (OTR) messaging protocol.

The Double Ratchet provides two critical security properties that go
beyond what a static shared key could provide:

1. **Forward secrecy** -- Compromising a current key does not expose
 past messages. Even if an attacker steals the current encryption key,
 they cannot derive previous keys and therefore cannot decrypt earlier
 messages.

2. **Post-compromise security (break-in recovery)** -- After a key
 compromise, future messages become secure again once a new DH ratchet
 step occurs. If an attacker temporarily gains access to key material,
 they lose access to the conversation as soon as the keys advance
 through a new Diffie-Hellman exchange.

The name "Double Ratchet" refers to the fact that it combines two
ratcheting mechanisms: a **DH ratchet** (Diffie-Hellman ratchet) that
advances when the conversation's turn changes, and a **symmetric
ratchet** (hash ratchet) that advances with every single message.

### The Three Chains

The Double Ratchet maintains three linked KDF chains: the root chain,
the sending chain, and the receiving chain.

```
Root Chain (KDF_RK)
 |
 |-- [DH ratchet step] --> new root key + new chain key
 |
 +-- Sending Chain (KDF_CK)
 | |-- advance --> Message Key 1 --> Encrypt msg 1
 | |-- advance --> Message Key 2 --> Encrypt msg 2
 | +-- advance --> Message Key 3 --> Encrypt msg 3
 |
 +-- Receiving Chain (KDF_CK)
 |-- advance --> Message Key 1 --> Decrypt msg 1
 |-- advance --> Message Key 2 --> Decrypt msg 2
 +-- advance --> Message Key 3 --> Decrypt msg 3
```

Each chain is a sequence of key derivation operations. The root chain
produces new sending and receiving chain keys through the DH ratchet.
The sending and receiving chains produce individual message keys through
the symmetric ratchet. Every message key is used exactly once and then
discarded.

### KDF Chain Operations

**KDF_RK: Root Key Derivation**

The root chain advances during a DH ratchet step. It takes the current
root key and a fresh DH output (from a new DH key exchange) and
produces a new root key and a new chain key.

Reference: `frontend/src/crypto/double-ratchet.ts`

```python
def _kdf_rk(self, root_key: bytes, dh_output: bytes) -> tuple[bytes, bytes]:
 hkdf = HKDF(
 algorithm = hashes.SHA256,
 length = HKDF_OUTPUT_SIZE * 2, # 64 bytes total
 salt = root_key, # current root key as salt
 info = b'',
 )
 output = hkdf.derive(dh_output)
 new_root_key = output[: HKDF_OUTPUT_SIZE] # first 32 bytes
 new_chain_key = output[HKDF_OUTPUT_SIZE :] # last 32 bytes
 return new_root_key, new_chain_key
```

HKDF-SHA256 is used with the current root key as the salt and the DH
output as the input key material. The output is 64 bytes, split in half:
the first 32 bytes become the new root key, the last 32 bytes become the
new chain key. This split ensures that knowing the chain key does not
reveal the root key, maintaining the separation between the root chain
and the message chains.

**KDF_CK: Chain Key Derivation**

The symmetric chains advance with every message. Each step takes the
current chain key and produces the next chain key and a message key.

Reference: `frontend/src/crypto/double-ratchet.ts`

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

Two separate HMAC-SHA256 computations are performed using the same chain
key but with different constants:

```
chain_key --+-- HMAC(chain_key, 0x01) --> next_chain_key (kept for future)
 |
 +-- HMAC(chain_key, 0x02) --> message_key (used once, discarded)
```

The use of different constants (0x01 and 0x02) is essential. If the same
constant were used, the chain key and message key would be identical,
which would mean that learning the message key (perhaps through a chosen
plaintext attack) would reveal the chain key and allow derivation of all
future keys. By using different HMAC inputs, the message key and the
next chain key are cryptographically independent: knowing one does not
reveal the other.

The message key is used exactly once to encrypt or decrypt a single
message, then discarded. The next chain key replaces the current chain
key and is used to derive the next message key. This one-way chain is
what provides forward secrecy within a single DH ratchet epoch.

### The DH Ratchet Step

The symmetric ratchet handles the simple case: sequential messages from
the same sender. But it cannot, on its own, provide post-compromise
security. If an attacker compromises a chain key, they can derive all
future message keys from that chain. The DH ratchet solves this.

A DH ratchet step occurs whenever the conversation's direction changes.
When Alice receives a message from Bob that includes a new DH public
key (one she has not seen before), she performs a DH ratchet step: she
generates a new DH keypair, performs a DH exchange with Bob's new public
key, and uses the output to derive new root and chain keys through
KDF_RK.

```
Message flow and DH ratchet steps:

Alice sends msgs 1,2,3 using DH keypair A1:
 A1 --> msg1(mk1), msg2(mk2), msg3(mk3)
 [symmetric ratchet advances 3 times, same DH key]

Bob receives, generates new DH keypair B1, sends reply:
 DH ratchet: root_key' = KDF_RK(root_key, DH(B1_priv, A1_pub))
 B1 --> msg4(mk1'), msg5(mk2')
 [new chain, new keys, A1 compromise no longer helps]

Alice receives, generates new DH keypair A2, sends reply:
 DH ratchet: root_key'' = KDF_RK(root_key', DH(A2_priv, B1_pub))
 A2 --> msg6(mk1''), msg7(mk2'')
 [new chain again, B1 compromise no longer helps]
```

Each DH ratchet step introduces fresh random entropy (from the newly
generated DH keypair) into the key derivation chain. This means that
even if an attacker had compromised all previous key material, the new
DH exchange produces a shared secret they cannot predict, and all
subsequent keys are secure again.

The implementation spans `frontend/src/crypto/double-ratchet.ts`:

- `_dh_ratchet_send` : Called when the sender needs to
 advance the ratchet. Generates a new DH keypair , performs
 DH with the peer's public key , and derives new root and
 sending chain keys .

- `_dh_ratchet_receive` : Called when a received message
 contains a new DH public key. Updates the peer public key ,
 performs DH with the existing private key to derive a new receiving
 chain key , then generates a new private key at line
 200 and performs another DH to derive a new sending chain key at lines
 208-211. This double DH step on the receiver side ensures both
 receiving and sending chains are updated.

### Out-of-Order Message Handling

Internet messages can arrive out of order. If Alice sends messages 1, 2,
3 and Bob receives 1, 3 (message 2 is delayed), Bob needs to:

1. Process message 1 normally (derive mk1, decrypt)
2. When processing message 3, recognize that message 2 was skipped
3. Derive and cache mk2 (so it can be used later when message 2 arrives)
4. Derive mk3 and decrypt message 3

The skipped message key mechanism handles this. Reference:
`frontend/src/crypto/double-ratchet.ts`.

`_store_skipped_message_keys` is called when the
received message number is greater than the expected message number. It
iterates through the gap, deriving and caching each skipped message key:

```python
chain_key = state.receiving_chain_key
for msg_num in range(state.receiving_message_number, until_message_number):
 chain_key, message_key = self._kdf_ck(chain_key)
 state.skipped_message_keys[(dh_public_key, msg_num)] = message_key
state.receiving_chain_key = chain_key
```

The skipped keys are stored in a dictionary keyed by `(dh_public_key,
message_number)`. This tuple key is necessary because message numbers
reset with each DH ratchet step: message 0 under DH key A1 is different
from message 0 under DH key A2.

`_try_skipped_message_key` checks whether a received
message matches a previously cached skipped key. If it does, the cached
key is used for decryption and then removed from the cache (it is
consumed by `dict.pop` ).

Security limits prevent abuse. An attacker who sends messages with
enormous message numbers could force the ratchet to derive and store
millions of keys, exhausting memory. Two limits are enforced:

- `MAX_SKIP_MESSAGE_KEYS = 1000` (`config.py`): No more than 1000
 message keys can be skipped in a single gap. If a message arrives
 claiming to be message number 5000 when we expect message 0, the
 decryption is rejected .

- `MAX_CACHED_MESSAGE_KEYS = 2000` (`config.py`): The total number
 of cached skipped keys across all ratchet epochs. If the cache is
 full, the oldest keys are evicted via
 `_evict_oldest_skipped_keys`.

### Forward Secrecy Proof

Here is a step-by-step walkthrough of why compromising key material at
time T does not expose messages before T.

Assume at message N, an attacker steals the current chain_key_N.

```
What the attacker CAN compute (forward direction):
 chain_key_N -----> HMAC(chain_key_N, 0x01) = chain_key_N+1
 chain_key_N+1 ---> HMAC(chain_key_N+1, 0x01) = chain_key_N+2
 ... and so on for all future chain keys

What the attacker CANNOT compute (backward direction):
 chain_key_N <-/-- chain_key_N-1

 Why? Because HMAC is a one-way function.

 chain_key_N = HMAC(chain_key_N-1, 0x01)

 Given chain_key_N, you cannot solve for chain_key_N-1.
 This would require inverting HMAC-SHA256, which is
 computationally infeasible (preimage resistance).

Therefore:
 message_key_N-1 = HMAC(chain_key_N-1, 0x02) <-- UNREACHABLE
 message_key_N-2 = HMAC(chain_key_N-2, 0x02) <-- UNREACHABLE
 message_key_1 = HMAC(chain_key_1, 0x02) <-- UNREACHABLE
```

The attacker can decrypt messages N+1, N+2, N+3, and so on (until the
next DH ratchet step introduces new entropy). But they cannot decrypt
any message before N. All past message keys are derived from chain keys
that are computationally inaccessible given only chain_key_N.

Now consider what happens at the next DH ratchet step. Bob sends a
message with a new DH public key B2. Alice generates a new keypair A3
and performs DH(A3_priv, B2_pub). This produces a fresh DH output that
the attacker cannot predict (because they do not know A3_priv, which
was just generated from secure random data). The new root key and chain
key are derived from this fresh DH output through KDF_RK. The
attacker's knowledge of the old chain key becomes useless. This is
post-compromise security: the system self-heals.


## AES-256-GCM Encryption

### What It Is

AES-256-GCM is the symmetric cipher used to encrypt each individual
message. It is an AEAD (Authenticated Encryption with Associated Data)
cipher, meaning it provides both confidentiality (nobody can read the
message without the key) and integrity (nobody can modify the message
without detection) in a single operation.

AES-256-GCM combines the AES block cipher in Counter mode (CTR) for
encryption with GHASH for authentication. The "256" refers to the key
size (256 bits / 32 bytes). The "GCM" stands for Galois/Counter Mode.

Each message key derived from the Double Ratchet's symmetric chain is
used as the AES-256-GCM key. A fresh random nonce (also called IV -
initialization vector) is generated for every message. The ciphertext
includes a 128-bit authentication tag that detects any tampering.

### How It's Used

The encryption flow is:

1. The Double Ratchet derives a message key (32 bytes) via KDF_CK
2. A random 12-byte nonce is generated using `os.urandom` (backend) or
 `crypto.getRandomValues` (frontend)
3. AES-256-GCM encrypts the plaintext using the message key and nonce
4. Associated data (sender and recipient identifiers) is authenticated
 but not encrypted
5. The output is ciphertext + a 16-byte authentication tag (GCM appends
 the tag to the ciphertext)

Backend implementation at `frontend/src/crypto/double-ratchet.ts`:

```python
def _encrypt_with_message_key(self, message_key, plaintext, associated_data):
 aesgcm = AESGCM(message_key)
 nonce = os.urandom(AES_GCM_NONCE_SIZE) # 12 bytes from config.py
 ciphertext = aesgcm.encrypt(nonce, plaintext, associated_data)
 return nonce, ciphertext
```

Backend decryption at `frontend/src/crypto/double-ratchet.ts` catches `InvalidTag`
exceptions , which indicate that the ciphertext was tampered
with, the wrong key was used, or the associated data does not match.
The error is re-raised as `ValueError("Message tampered or corrupted")`
.

Frontend implementation at `frontend/src/crypto/primitives.ts` uses the WebCrypto
API:

```typescript
const nonce = generateRandomBytes(AES_GCM_NONCE_SIZE)
const ciphertext = await subtle.encrypt(
 {
 name: "AES-GCM",
 iv: nonce.buffer,
 additionalData: associatedData?.buffer,
 },
 cryptoKey,
 plaintext.buffer
)
```

Frontend decryption at `frontend/src/crypto/primitives.ts` mirrors this with
`subtle.decrypt`. The WebCrypto API throws a `DOMException` if
authentication fails, which is functionally equivalent to the Python
`InvalidTag` exception.

### Why Not Just AES-CBC?

AES-CBC (Cipher Block Chaining) is the other commonly seen AES mode. It
provides confidentiality but not integrity. A CBC-encrypted message can
be modified by an attacker (bit-flipping attacks) without the recipient
detecting the modification. To add integrity, you need a separate HMAC
computation (Encrypt-then-MAC or MAC-then-Encrypt), which adds
complexity and opportunities for implementation errors.

GCM handles both in a single operation. It also has practical
performance advantages: the CTR-mode encryption in GCM is parallelizable
across CPU cores and benefits from AES-NI hardware instructions, while
CBC is inherently sequential (each block depends on the previous
ciphertext block).

AES-GCM is the NIST-recommended mode for new applications (NIST SP
800-38D). It is the mandatory cipher suite in TLS 1.3. There is no
security reason to prefer CBC over GCM for new implementations.

### Parameters

As defined in `config.py`:

```
AES_GCM_KEY_SIZE = 32 (256 bits)
AES_GCM_NONCE_SIZE = 12 (96 bits)
HKDF_OUTPUT_SIZE = 32 (256 bits)
```

The 12-byte (96-bit) nonce is the recommended size for GCM. Longer
nonces are allowed by the specification but require additional internal
processing. The authentication tag is 128 bits (16 bytes), which is the
full-length tag and the default for both the Python `cryptography`
library and WebCrypto.

With a 256-bit key, AES-256-GCM provides 128-bit security against key
recovery attacks (Grover's algorithm would reduce AES-256 to 128-bit
security on a quantum computer, but AES-128 would drop to 64-bit, which
is why 256-bit keys are the forward-looking choice).

The nonce must be unique per key. Because each message key from the
Double Ratchet is used exactly once, the nonce uniqueness requirement is
automatically satisfied even if the random number generator produced a
collision: the same nonce with a different key is not a problem. This is
a subtle but important point. The Double Ratchet's key-per-message
design means that nonce reuse (which would be catastrophic with a static
key) is not a realistic concern here.


## WebAuthn / Passkeys

### What It Is

WebAuthn (Web Authentication) is a W3C standard (first published in
March 2019, Level 2 in April 2021, Level 3 in progress) for
passwordless authentication using public key cryptography. Instead of
passwords, users authenticate using asymmetric key pairs managed by an
authenticator: a hardware security key (YubiKey, SoloKey), a platform
authenticator (Touch ID, Face ID, Windows Hello, Android biometrics), or
a cross-platform authenticator accessed through a phone.

The term "Passkey" refers to a discoverable credential (also called a
"resident key") that is synced across devices through a platform
credential manager (iCloud Keychain, Google Password Manager, 1Password,
etc.). Passkeys are the consumer-friendly branding for WebAuthn
discoverable credentials.

The key insight is that with WebAuthn, the private key never leaves the
authenticator. The server stores only the public key and a credential
ID. Authentication is a challenge-response protocol: the server sends a
random challenge, the authenticator signs it with the private key, and
the server verifies the signature with the stored public key. No secret
is transmitted, no secret is stored on the server, and there is nothing
for an attacker to steal from the server that would allow them to
impersonate the user.

### Why Not Passwords?

Passwords are the primary attack vector for authentication compromise.
Here is why, specifically in the context of an encrypted messaging
application:

**Phishing.** An attacker creates a convincing replica of the login page
and tricks the user into entering their password. With WebAuthn, the
authenticator cryptographically binds the credential to the origin
(domain name) of the website. If the user visits `evil-chat.com`
instead of `real-chat.com`, the authenticator will not use the credential
for `real-chat.com` because the origin does not match. The user cannot
be tricked into authenticating to the wrong site because the
authenticator will simply not respond to the challenge. This is
automatic and requires no user awareness of the attack.

**Credential stuffing.** Users reuse passwords across services. When one
service is breached (and breaches of password databases happen
constantly -- Collection #1 in 2019 exposed 773 million email/password
pairs), attackers try those passwords against other services. WebAuthn
credentials are unique per relying party (website). There is no password
to reuse.

**Keyloggers.** Malware that captures keystrokes can record passwords as
users type them. WebAuthn authentication uses biometric verification
(fingerprint, face) or PIN entry on the authenticator device, not the
keyboard. Even if a keylogger captured a PIN, the PIN alone is useless
without physical possession of the authenticator device.

**Server compromise.** If a server stores password hashes and the
database is stolen, attackers can attempt offline cracking. The 2023
LastPass breach exposed encrypted password vaults for 25+ million users;
users with weak master passwords had their vaults cracked. With
WebAuthn, the server stores only public keys. Stealing public keys gives
the attacker nothing: you cannot derive a private key from a public key,
and you cannot forge a signature without the private key.

### Registration Flow

```
Step 1: Client requests registration options
 Client ----> POST /auth/register/begin ----> Server

 Server:
 - Generates 32-byte random challenge (secrets.token_bytes)
 - Stores challenge in Redis with 10-minute TTL
 - Returns WebAuthn PublicKeyCredentialCreationOptions

Step 2: Browser creates credential
 Browser ----> navigator.credentials.create(options) ----> Authenticator

 Authenticator:
 - Prompts user for biometric/PIN verification
 - Generates new ECDSA or EdDSA keypair
 - Stores private key internally (NEVER exported)
 - Returns attestation object (signed credential public key)

Step 3: Client sends attestation for verification
 Client ----> POST /auth/register/complete ----> Server

 Server:
 - Verifies attestation signature
 - Verifies challenge matches stored value
 - Extracts credential public key and credential ID
 - Stores PUBLIC KEY + credential ID in PostgreSQL
 - Deletes challenge from Redis
 - Private key STAYS on authenticator -- server never sees it
```

Implementation reference: `backend/app/core/passkey/passkey_manager.py`
(`generate_registration_options`). a 32-byte challenge is
generated: `challenge = secrets.token_bytes(WEBAUTHN_CHALLENGE_BYTES)`.
At lines 74-87, the WebAuthn options are constructed with RP
configuration, user information, and authenticator requirements. The
authenticator selection specifies
`ResidentKeyRequirement.REQUIRED`, which forces creation of a
discoverable credential (passkey).

Registration verification at `backend/app/core/passkey/passkey_manager.py`
(`verify_registration`) calls `verify_registration_response` at lines
105-110, which validates the attestation object, checks the challenge,
verifies the RP ID, and confirms the origin.

### Authentication Flow

```
Step 1: Client requests authentication options
 Client ----> POST /auth/authenticate/begin ----> Server

 Server:
 - Generates new 32-byte challenge
 - Stores challenge in Redis with 10-minute TTL
 - Returns WebAuthn PublicKeyCredentialRequestOptions

Step 2: Browser signs challenge
 Browser ----> navigator.credentials.get(options) ----> Authenticator

 Authenticator:
 - Prompts user for biometric/PIN
 - Signs challenge with stored private key
 - Increments signature counter
 - Returns assertion (signed challenge + counter)

Step 3: Client sends assertion for verification
 Client ----> POST /auth/authenticate/complete ----> Server

 Server:
 - Retrieves stored public key from PostgreSQL
 - Verifies signature using stored public key
 - Verifies challenge matches stored value
 - Checks signature counter INCREASED (clone detection!)
 - Updates stored counter value
 - Returns authenticated session
```

Implementation reference: `backend/app/core/passkey/passkey_manager.py`
(`generate_authentication_options`). a fresh challenge is
generated. At lines 148-153, WebAuthn authentication options are
constructed.

Authentication verification at `backend/app/core/passkey/passkey_manager.py`
(`verify_authentication`). At lines 173-180, the assertion is verified
against the expected challenge, RP ID, origin, and stored credential
public key. The critical clone detection check follows.

### Clone Detection

Hardware authenticators (YubiKeys, Titan keys, etc.) maintain an
internal signature counter that increments every time the authenticator
is used. This counter is included in the signed assertion data. The
server stores the latest counter value and checks that each new
authentication presents a higher counter.

If the server receives an assertion with a counter value that has not
increased (or has decreased), it indicates one of two things:

1. The authenticator hardware was cloned (its key material was
 extracted and loaded onto a second device)
2. A replay attack is being attempted

Both scenarios are security incidents that warrant blocking
authentication and alerting the user.

Reference: `backend/app/core/passkey/passkey_manager.py`:

```python
if (credential_current_sign_count != 0 and new_sign_count != 0
 and new_sign_count <= credential_current_sign_count):
 logger.error(
 "Signature counter did not increase: current=%s, new=%s. "
 "Possible cloned authenticator detected!",
 credential_current_sign_count,
 new_sign_count
 )
 raise ValueError(
 "Signature counter anomaly detected - potential cloned authenticator"
 )
```

The conditions `credential_current_sign_count != 0` and
`new_sign_count != 0` are defensive: some authenticators (particularly
platform authenticators and passkeys) always report a counter of 0,
indicating that they do not implement counter-based clone detection.
For those authenticators, the clone detection check is skipped because
it would always trigger a false positive. This is consistent with the
WebAuthn specification's guidance on handling authenticators that do not
support signature counters.


## Constant-Time Comparison

A detail worth calling out: `frontend/src/crypto/primitives.ts` implements a
constant-time byte array comparison:

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

This function compares two byte arrays in constant time, meaning the
execution time does not depend on where the first difference occurs.
A naive comparison (`a[i] !== b[i]` with an early return) leaks
information through timing: if the first byte differs, the function
returns immediately, and an attacker measuring response time can deduce
that the first byte was wrong. By iterating through all bytes and
OR-ing the XOR results, the function always takes the same amount of
time regardless of whether the arrays match at byte 0 or byte 31.

Timing side-channel attacks are not theoretical. In 2009, Nate Lawson
and Taylor Nelson demonstrated practical timing attacks against HMAC
verification in a web application framework, recovering the correct HMAC
one byte at a time. The constant-time comparison eliminates this attack
vector entirely.


## How These Concepts Relate

The following diagram shows how the five major concepts connect to form
the full security architecture of the application:

```
+-----------------------------------------------------------+
| AUTHENTICATION LAYER |
| |
| WebAuthn/Passkeys |
| | |
| +--> User identity established |
| +--> No password to steal, phish, or brute force |
| +--> Clone detection via signature counter |
| | |
| v |
| +----------------------------------------------------+ |
| | KEY AGREEMENT LAYER | |
| | | |
| | X3DH Key Exchange | |
| | +--> Asynchronous (works when peer is offline) | |
| | +--> 4 DH operations for mutual authentication | |
| | +--> Produces initial shared secret (32 bytes) | |
| | | | |
| | v | |
| | Double Ratchet Initialization | |
| | +--> Shared secret becomes root key | |
| | +--> Sending and receiving chains created | |
| +----------------------------------------------------+ |
| | |
| v |
| +----------------------------------------------------+ |
| | MESSAGE ENCRYPTION LAYER | |
| | | |
| | Double Ratchet (ongoing) | |
| | +--> KDF_CK derives per-message keys | |
| | +--> DH ratchet provides post-compromise security| |
| | +--> Skipped key cache handles out-of-order msgs | |
| | | | |
| | v | |
| | AES-256-GCM | |
| | +--> Encrypts plaintext with message key | |
| | +--> Random 12-byte nonce per message | |
| | +--> Authentication tag detects tampering | |
| +----------------------------------------------------+ |
| | |
| v |
| +----------------------------------------------------+ |
| | TRANSPORT LAYER | |
| | | |
| | WebSocket (real-time delivery) | |
| | +--> Carries encrypted blobs between clients | |
| | +--> Server sees only ciphertext + metadata | |
| | | |
| | SurrealDB (persistence) | |
| | +--> Stores encrypted messages at rest | |
| | +--> No decryption capability on server | |
| +----------------------------------------------------+ |
+-----------------------------------------------------------+
```

The layers interact in a strict top-down sequence for new conversations:

1. The user authenticates with WebAuthn (proving their identity without
 a password)
2. X3DH establishes a shared secret with the peer (even if the peer is
 offline)
3. The shared secret initializes the Double Ratchet
 (`frontend/src/crypto/double-ratchet.ts`)
4. Each message is encrypted with a unique AES-256-GCM key derived from
 the ratchet (`frontend/src/crypto/double-ratchet.ts`)
5. The encrypted message is transmitted via WebSocket and stored in
 SurrealDB (`backend/app/services/message_service.py`)

For ongoing conversations, only steps 4 and 5 repeat. The X3DH
handshake happens once per conversation. The Double Ratchet then runs
autonomously, deriving fresh keys for every message without any further
server interaction for key management.


## Industry Standards

This section maps the project's security measures to specific industry
frameworks. These mappings are useful for compliance discussions,
security audits, and threat modeling.

### OWASP Top 10 (2021)

**A02: Cryptographic Failures** -- Formerly "Sensitive Data Exposure,"
this category covers failures in cryptographic implementation. This
project addresses it through:
- AES-256-GCM with HKDF-SHA256 key derivation (no weak algorithms)
- 256-bit keys meeting NIST minimum requirements for post-2030 use
- Per-message unique keys (no key reuse)
- Proper nonce generation via CSPRNG (`os.urandom`, `crypto.getRandomValues`)
- No storage of plaintext on the server

**A04: Insecure Design** -- Covers architecture-level security
weaknesses. The zero-knowledge architecture prevents entire classes of
server-side attacks:
- Server compromise does not reveal message content
- No server-side decryption keys to steal
- Prekey bundles contain only public key material
- Store-and-forward model treats all messages as opaque blobs

**A07: Identification and Authentication Failures** -- Covers broken
authentication. WebAuthn eliminates the most common authentication
attacks:
- No passwords means no credential stuffing (CWE-521)
- Origin binding prevents phishing (CWE-352)
- Signature counters detect cloned authenticators
- Challenge-response prevents replay attacks

### MITRE ATT&CK

**T1557: Adversary-in-the-Middle** -- An attacker intercepts
communications between two parties. E2E encryption with X3DH mutual
authentication prevents meaningful MITM attacks. Even if an attacker
controls the network path, they see only AES-256-GCM ciphertext. The
X3DH signed prekey verification (using Ed25519 signatures) prevents the
attacker from substituting their own keys.

**T1528: Steal Application Access Token** -- An attacker steals an
authentication token to impersonate a user. WebAuthn credentials are
cryptographically bound to the relying party origin. A token stolen from
one site cannot be used on another. The private key never leaves the
authenticator, so there is no token to steal from the server or from
network traffic.

**T1110: Brute Force** -- An attacker attempts to guess credentials
through exhaustive trial. With WebAuthn, there are no passwords to brute
force. Authentication requires physical possession of the authenticator
and biometric verification (or PIN), making remote brute force
impossible. The challenge changes with every authentication attempt,
preventing replay of captured assertions.

### CWE References

**CWE-327: Use of a Broken or Risky Cryptographic Algorithm** -- This
project uses exclusively NIST-approved and widely-vetted algorithms:
X25519 (Curve25519 ECDH), Ed25519 (EdDSA), AES-256-GCM, HMAC-SHA256,
HKDF-SHA256. No custom cryptographic primitives are implemented. Both
the Python `cryptography` library and the browser WebCrypto API provide
well-tested implementations.

**CWE-326: Inadequate Encryption Strength** -- 256-bit symmetric keys
(AES-256) and 256-bit elliptic curve keys (X25519, Ed25519) provide a
128-bit security level, which exceeds NIST's minimum recommendation of
112 bits for use through 2030+ (NIST SP 800-57 Part 1).

**CWE-330: Use of Insufficiently Random Values** -- Randomness comes
from two sources: `os.urandom` on the backend (which reads from the
operating system's CSPRNG -- `/dev/urandom` on Linux) and
`crypto.getRandomValues` on the frontend (which uses the browser's
CSPRNG). Both are cryptographically secure. Nonce generation at
`frontend/src/crypto/double-ratchet.ts` and `frontend/src/crypto/primitives.ts` use these
exclusively.

**CWE-311: Missing Encryption of Sensitive Data** -- All message content
is encrypted at rest (SurrealDB stores only ciphertext) and in transit
(WebSocket over TLS carries AES-256-GCM ciphertext). The Double Ratchet
state itself is serialized and stored, but this state does not contain
any plaintext; it contains key material for future messages.


## Real-World Case Studies

### Case Study 1: The 2020 Zoom E2E Encryption Controversy

**Timeline.** In March 2020, The Intercept published an investigation
revealing that Zoom's claims of "end-to-end encryption" were false. The
Citizen Lab at the University of Toronto published a follow-up report in
April 2020, identifying that Zoom used AES-128 in ECB mode and that
encryption keys were generated by Zoom's servers and transmitted to
participants through Zoom's infrastructure. In November 2020, the FTC
issued a complaint, and Zoom agreed to a settlement requiring them to
implement a comprehensive security program and cease misrepresenting
their encryption.

**What failed architecturally.** Zoom's design placed the encryption
keys on the server. The connection between the client and the server was
encrypted (transport encryption via TLS), and the media streams between
the server and the participants were encrypted with AES-128, but the
server generated and held all key material. This meant Zoom's servers
could decrypt every call. The use of ECB mode (Electronic Codebook) was
an additional failure: ECB encrypts each block independently, meaning
identical plaintext blocks produce identical ciphertext blocks, which
leaks structural patterns in the data. ECB has been considered insecure
for decades and is explicitly warned against in every modern
cryptography textbook.

**How this project prevents the same failure.** In this project, the
server never generates or holds encryption keys for message content.
Key generation happens in two places:

1. On the backend, `frontend/src/crypto/x3dh.ts` generates X25519 identity
 keypairs using `X25519PrivateKey.generate`, which calls into
 OpenSSL's random number generator. These keys are for the X3DH
 protocol, and the private keys are stored in the database for the
 server-side key exchange path.

2. On the frontend, `frontend/src/crypto/primitives.ts` generates X25519 keypairs
 using the WebCrypto API (`subtle.generateKey`), which uses the
 browser's hardware-backed CSPRNG. In the client-side encryption
 model, these keys never leave the browser.

The `store_encrypted_message` function (`backend/app/services/message_service.py`)
receives pre-encrypted ciphertext from the client and stores it directly
in SurrealDB without any server-side decryption. The
server's role is explicitly that of a blind relay. Even if the entire
server infrastructure were compromised, the attacker would obtain only
encrypted blobs with no corresponding decryption keys.

### Case Study 2: Signal Protocol Adoption by WhatsApp (2016)

**Background.** In November 2014, Open Whisper Systems announced a
partnership with WhatsApp to integrate the Signal Protocol into the
WhatsApp messaging client. The rollout happened incrementally:
TextSecure's Axolotl protocol (later renamed to the Signal Protocol)
was first deployed for Android-to-Android messages, then extended to
group messages, media, and voice calls on all platforms. Full deployment
was announced in April 2016, making WhatsApp the largest deployment of
E2E encryption in history, covering over 1 billion users at the time.

**Technical details.** WhatsApp implemented the same X3DH + Double
Ratchet combination used in this project. Each message gets a unique
AES key through the ratchet mechanism, providing forward secrecy across
billions of daily messages. WhatsApp's implementation stores prekey
bundles on their servers (just as this project does via
`backend/app/services/prekey_service.py`), allowing asynchronous session
establishment. The X3DH handshake is performed when a user initiates a
new conversation, and the Double Ratchet runs continuously thereafter.

**Impact.** When the Brazilian government ordered WhatsApp to provide
message content in 2016, WhatsApp demonstrated that they architecturally
could not comply: they did not possess the decryption keys. This was not
a policy decision or a promise; it was a mathematical fact. The protocol
makes it provably impossible for the server to decrypt messages. The
same situation occurred with FBI requests in the United States and
government demands in India and the UK.

**Connection to this project.** The X3DH implementation at
`frontend/src/crypto/x3dh.ts` and the Double Ratchet at
`frontend/src/crypto/double-ratchet.ts` implement the same cryptographic operations
described in the Signal Protocol specification. The same four DH
operations , the same HKDF derivation ,
the same KDF chain operations (lines 79-109 of frontend/src/crypto/double-ratchet.ts), and
the same skipped message key mechanism . The protocol
specifications are public, the formal security proofs are published, and
the implementation follows them directly.

### Case Study 3: The 2023 LastPass Breach

**Timeline.** In August 2022, an attacker compromised a LastPass
developer's workstation through a vulnerable third-party media software
package. Using the developer's credentials, the attacker accessed
LastPass's development environment and stole source code and technical
information. In a second incident, the attacker used information from
the first breach to target a DevOps engineer's home computer, installing
a keylogger that captured the engineer's master password for a LastPass
corporate vault. With this access, the attacker exfiltrated encrypted
customer password vaults and backup data from LastPass's cloud storage.

**What was exposed.** The encrypted vaults for approximately 25.6
million users were stolen. While the vaults were encrypted with AES-256
using each user's master password as the key derivation input, the
security of the vaults depended entirely on the strength of the user's
master password. Users with short, common, or previously-breached master
passwords had their vaults cracked through offline brute-force attacks.
The breach also exposed unencrypted metadata including website URLs,
which revealed which services each user had accounts with.

**Connection to this project.** The LastPass breach demonstrates
precisely why WebAuthn/Passkeys are superior to password-based
authentication, even when the passwords are used to derive encryption
keys.

In this project's WebAuthn implementation
(`backend/app/core/passkey/passkey_manager.py`), there is no password. The user
authenticates with a biometric or PIN on their authenticator device. The
authenticator holds an ECDSA or EdDSA private key that is hardware-bound
and never exported. If the server database is fully compromised, the
attacker obtains only credential public keys and credential IDs. Public
keys cannot be reversed to obtain private keys (this would require
solving the elliptic curve discrete logarithm problem, which is
computationally infeasible). There is no master password to brute force,
no password hash to crack, and no password-equivalent secret stored on
the server.

The contrast is stark: LastPass stored user secrets protected by a
user-chosen password. This project stores user secrets protected by a
hardware-bound private key that the user cannot choose, cannot weaken,
and cannot accidentally reuse on another site.


## Testing Your Understanding

Before moving on to the architecture document, you should be able to
answer these questions. If you cannot answer one confidently, re-read the
relevant section.

1. **Why does X3DH need four separate DH operations instead of just
 one?** What specific security property does each operation provide?
 What attack becomes possible if any single operation is removed?

2. **If an attacker compromises a Double Ratchet chain key at message N,
 which messages can they decrypt?** Which messages remain protected?
 When does the attacker lose access? Trace through the KDF_CK function
 to prove your answer.

3. **Why is WebAuthn resistant to phishing attacks, while traditional
 passwords are not?** What property of the WebAuthn protocol prevents
 a fake login page from capturing usable credentials? Hint: think
 about what the authenticator checks before signing the challenge.

4. **What happens if Alice sends Bob messages 1, 2, 3, 4, 5 and Bob
 receives them in order 1, 3, 5, 2, 4?** Walk through the skipped
 message key mechanism for each received message. How many keys are
 cached after processing message 3? After processing message 5?

5. **Why does the Double Ratchet use two different HMAC constants (0x01
 and 0x02) in KDF_CK?** What would go wrong if both the chain key and
 the message key were derived with the same constant?


## Further Reading

### Essential Specifications

- The Signal Protocol specifications: https://signal.org/docs/
- X3DH specification: https://signal.org/docs/specifications/x3dh/
- Double Ratchet specification: https://signal.org/docs/specifications/doubleratchet/
- WebAuthn Level 3 specification: https://www.w3.org/TR/webauthn-3/

### Academic Analysis

- "A Formal Security Analysis of the Signal Messaging Protocol" --
 Cohn-Gordon, Cremers, Dowling, Garratt, Stebila. IEEE EuroS&P 2017.
 Formal proof that the Signal Protocol meets its claimed security
 properties (authenticated key exchange, forward secrecy, post-compromise
 security) under the Gap-DH assumption.

- "The Signal Protocol: A Cryptographic Analysis" -- Cohn-Gordon et al.
 (2017). Extended version with proofs covering the X3DH and Double
 Ratchet components individually and composed.

- "On Ends-to-Ends Encryption: Asynchronous Group Messaging with Strong
 Security Guarantees" -- Cohn-Gordon et al. IEEE S&P 2018. Extends the
 analysis to group messaging scenarios.

### FIDO and WebAuthn

- FIDO2 technical overview: https://fidoalliance.org/fido2/
- FIDO Alliance whitepaper on passkeys:
 https://fidoalliance.org/passkeys/
- NIST SP 800-63B Digital Identity Guidelines (authenticator types and
 assurance levels)

### Cryptographic Primitives

- Daniel J. Bernstein, "Curve25519: new Diffie-Hellman speed records"
 (2006) -- The paper introducing the X25519 function used for DH in
 this project.

- Daniel J. Bernstein, Niels Duif, Tanja Lange, Peter Schwabe, Bo-Yin
 Yang, "High-speed high-security signatures" (2012) -- The paper
 introducing Ed25519 used for signing prekeys.

- NIST SP 800-38D, "Recommendation for Block Cipher Modes of Operation:
 Galois/Counter Mode (GCM) and GMAC" -- The specification for the
 AES-GCM mode used for message encryption.

- Hugo Krawczyk, "Cryptographic Extraction and Key Derivation: The HKDF
 Scheme" (2010) -- The paper behind HKDF, the key derivation function
 used throughout the Double Ratchet.

### Historical Context

- Nikita Borisov, Ian Goldberg, Eric Brewer, "Off-the-Record
 Communication, or, Why Not To Use PGP" (2004) -- The OTR protocol
 that introduced the concept of deniable, forward-secret messaging and
 directly inspired the Signal Protocol's design.

- Whitfield Diffie and Martin Hellman, "New Directions in Cryptography"
 (1976) -- The original paper introducing public key cryptography and
 the Diffie-Hellman key exchange that underlies X3DH.

- Phil Zimmermann and PGP: The "Crypto Wars" of the 1990s, where the
 US government attempted to restrict the export of strong cryptography.
 Zimmermann published PGP's source code in a printed book to circumvent
 export controls under First Amendment protection. This history is why
 cryptographic software can be freely distributed today.
