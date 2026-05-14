# System Architecture

This document describes the full architecture of the encrypted P2P chat application. It implements a subset of the Signal Protocol (X3DH + Double Ratchet) for end-to-end encryption, with WebAuthn/Passkeys for passwordless authentication. The server is a relay that stores ciphertext blobs and never sees plaintext message content.

Everything that follows is grounded in the actual source code. File references use the format `filename.py:line-range` relative to the backend `app/` or frontend `src/` directory.

---

## High-Level Architecture

```
 HTTPS (TLS)
 ┌────────────────────────────────────────────────────────────┐
 │ Client Browser │
 │ ┌──────────────────────────────────────────────────────┐ │
 │ │ SolidJS 1.9 + TypeScript 5.9 │ │
 │ │ ┌──────────────┐ ┌──────────────┐ ┌────────────┐ │ │
 │ │ │ WebCrypto │ │ IndexedDB │ │ nanostores │ │ │
 │ │ │ X25519 │ │ Private │ │ Reactive │ │ │
 │ │ │ Ed25519 │ │ Keys │ │ State │ │ │
 │ │ │ AES-256-GCM │ │ Ratchet │ │ │ │ │
 │ │ │ HKDF-SHA256 │ │ States │ │ │ │ │
 │ │ └──────────────┘ └──────────────┘ └────────────┘ │ │
 │ └──────────────────────────┬───────────────────────────┘ │
 │ │ │
 └──────────────────────────────┼──────────────────────────────┘
 │
 HTTPS + WSS │
 │
 ┌──────────────────────────────┼──────────────────────────────┐
 │ Nginx Reverse Proxy │ │
 │ ┌───────────────────────────┴──────────────────────────┐ │
 │ │ /api/* ──────► HTTP ──────► FastAPI :8000 │ │
 │ │ /ws ──────► WS ──────► FastAPI :8000 │ │
 │ │ /* ──────► Static files (SolidJS build) │ │
 │ └──────────────────────────────────────────────────────┘ │
 └──────────────────────────────┬──────────────────────────────┘
 │
 ┌──────────────────────────────┼──────────────────────────────┐
 │ FastAPI Backend │ │
 │ (Python 3.13, ORJSONResponse, async/await throughout) │
 │ ┌──────────────────────────────────────────────────────┐ │
 │ │ Routers: auth, rooms, encryption, websocket │ │
 │ │ Services: auth, prekey, message, presence, websocket│ │
 │ │ Core: x3dh, double_ratchet, passkey, surreal, redis │ │
 │ └────────┬──────────────┬──────────────┬───────────────┘ │
 │ │ │ │ │
 └───────────┼──────────────┼──────────────┼───────────────────┘
 │ │ │
 asyncpg │ WebSocket │ redis. │
 (TCP 5432) │ (WS 8000) │ asyncio │
 │ │ (TCP 6379) │
 ┌───────────┴──┐ ┌───────┴──────┐ ┌───┴────────────┐
 │ PostgreSQL │ │ SurrealDB │ │ Redis 8 │
 │ 16-alpine │ │ (latest) │ │ (alpine) │
 │ │ │ │ │ │
 │ Auth data │ │ Messages │ │ Challenges │
 │ Credentials │ │ Presence │ │ Rate limits │
 │ X3DH keys │ │ Rooms │ │ │
 │ Ratchet │ │ Live │ │ TTL-based │
 │ states │ │ queries │ │ auto-expiry │
 └──────────────┘ └──────────────┘ └────────────────┘
```

A few things worth noting about this diagram:

1. All three databases serve distinct purposes. PostgreSQL handles relational data that requires ACID transactions (users, credentials, cryptographic keys). SurrealDB handles real-time data that benefits from live query push notifications (messages, presence). Redis handles ephemeral data that needs automatic expiry (WebAuthn challenges, rate limit counters).

2. The WebSocket connection between client and FastAPI is the primary channel for real-time messaging. HTTP is used only for auth flows and key management.

3. The client does all encryption and decryption. The server receives ciphertext and stores it as-is. This is the central design constraint that everything else follows from.

---

## Component Breakdown

### FastAPI Backend

**Purpose:** API server that handles authentication, key management, message relay, and WebSocket connections.

**Key File:** `factory.py`

The application uses the factory pattern. `create_app` builds the FastAPI instance:

```
create_app (factory.py)
 ├── FastAPI(
 │ title = settings.APP_NAME,
 │ default_response_class = ORJSONResponse,
 │ lifespan = lifespan,
 │ )
 ├── CORSMiddleware (factory.py)
 ├── GZipMiddleware, minimum_size=1000 (factory.py)
 ├── register_exception_handlers (factory.py)
 ├── Root endpoint "/" (factory.py)
 ├── Health endpoint "/health" (factory.py)
 └── Routers:
 ├── auth_router → /auth/*
 ├── rooms_router → /rooms/*
 ├── encryption_router → /encryption/*
 └── websocket_router → /ws
```

The lifespan manager runs database connections on startup and disconnections on shutdown:

```
lifespan(app) (factory.py)
 Startup:
 1. await init_db → PostgreSQL tables via SQLModel
 2. await redis_manager.connect → Redis connection pool
 3. await surreal_db.connect → SurrealDB WebSocket connection
 Shutdown:
 1. await redis_manager.disconnect
 2. await surreal_db.disconnect
```

The startup order matters. PostgreSQL is initialized first because the auth tables must exist before any request processing. Redis and SurrealDB follow because they depend on having a running application context. If any of these fail, the application does not start.

**Interfaces:**

| Route Prefix | Purpose | Key Endpoints |
|---|---|---|
| `/auth` | WebAuthn registration + login + session | `register/begin`, `register/complete`, `authenticate/begin`, `authenticate/complete`, `me`, `logout`, `users/search` |
| `/encryption` | Public prekey bundle storage and lookup | `prekey-bundle/{id}`, `upload-keys/{id}` |
| `/rooms` | Chat room CRUD (membership-gated) | List, create, get, delete, get messages |
| `/ws` | WebSocket endpoint (session-cookie authenticated) | Real-time messaging, typing, presence, receipts |

---

### WebSocket Layer

**Purpose:** Real-time bidirectional communication for messaging, typing indicators, presence updates, and read receipts.

**Key Files:** `core/websocket_manager.py`, `api/websocket.py`, `services/websocket_service.py`

The `ConnectionManager` class (`websocket_manager.py`) is the center of the real-time system. It maintains three dictionaries:

```python
self.active_connections: dict[UUID, list[WebSocket]] = {}
self.live_query_ids: dict[UUID, str] = {}
self.heartbeat_tasks: dict[UUID, asyncio.Task] = {}
```

The first maps user IDs to lists of WebSocket connections. Each user can have up to 5 simultaneous connections (`WS_MAX_CONNECTIONS_PER_USER = 5`, `config.py`). This supports multi-device usage without exhausting server resources. When a sixth connection attempt arrives, the manager sends an error and closes the socket (`websocket_manager.py`).

**Connection lifecycle:**

```
connect(websocket, user_id) (websocket_manager.py)
 1. Accept WebSocket
 2. Check connection limit (max 5 per user)
 3. Add to active_connections pool
 4. Set user online via presence_service
 5. Start heartbeat loop (30s interval)
 6. Subscribe to SurrealDB live query for user's messages
 7. Return True

disconnect(websocket, user_id) (websocket_manager.py)
 1. Remove WebSocket from user's connection list
 2. If last connection:
 a. Set user offline via presence_service
 b. Kill SurrealDB live query
 c. Cancel heartbeat task
```

**Heartbeat:** The `_heartbeat_loop` method (`websocket_manager.py`) sends a ping every `WS_HEARTBEAT_INTERVAL` seconds (30s, from `config.py`). If the send fails, the connection is marked dead and disconnected. This catches silently dropped connections that TCP keepalive alone would miss.

**Live query subscription:** When a user connects, `_subscribe_to_messages` (`websocket_manager.py`) registers a SurrealDB live query that watches for new messages where the user is the recipient. SurrealDB pushes new messages to the server in real-time through this subscription. The callback wraps updates and dispatches them through `_handle_live_message` (`websocket_manager.py`), which forwards the encrypted payload to all of the user's active WebSocket connections.

**Message routing:** The WebSocket endpoint (`websocket.py`) is thin. It accepts connections, delegates to `connection_manager.connect`, and then sits in a loop reading JSON messages. Each message gets routed by `websocket_service.route_message`, which dispatches based on the `type` field:

```
route_message(websocket, user_id, message) (backend/app/services/websocket_service.py)
 ├── "encrypted_message" → handle_encrypted_message
 ├── "typing" → handle_typing_indicator
 ├── "presence" → handle_presence_update
 ├── "receipt" → handle_read_receipt
 ├── "heartbeat" → handle_heartbeat
 └── unknown → send error response
```

**Dead connection cleanup:** When `send_message` (`websocket_manager.py`) fails to send to a connection, it collects the dead connection and calls `disconnect` on it. This prevents stale connections from accumulating.

---

### Encryption Engine

**Purpose:** Implements the Signal Protocol cryptographic primitives for end-to-end encryption.

**Key Files:** `frontend/src/crypto/frontend/src/crypto/x3dh.ts`, `frontend/src/crypto/frontend/src/crypto/double-ratchet.ts`, `frontend/src/crypto/primitives.ts`

The encryption system has two layers:

1. **X3DH (Extended Triple Diffie-Hellman):** Establishes a shared secret between two users who have never communicated before, even if one of them is offline.

2. **Double Ratchet:** Uses the X3DH shared secret to derive per-message encryption keys with forward secrecy. Every message gets a unique key, and compromising one key does not reveal past or future messages.

**X3DHManager** (`frontend/src/crypto/x3dh.ts`) handles:
- Key generation for identity keys (X25519 for DH, Ed25519 for signing)
- Signed prekey generation with Ed25519 signatures (`frontend/src/crypto/x3dh.ts`)
- One-time prekey generation (`frontend/src/crypto/x3dh.ts`)
- Signed prekey verification (`frontend/src/crypto/x3dh.ts`)
- Sender-side X3DH exchange (`frontend/src/crypto/x3dh.ts`)
- Receiver-side X3DH exchange (`frontend/src/crypto/x3dh.ts`)

The X3DH exchange on the sender side (`perform_x3dh_sender`, lines 208-281) works like this:

```
Alice wants to message Bob (who might be offline):

1. Alice fetches Bob's prekey bundle from server:
 - Bob's identity key (IK_B)
 - Bob's signed prekey (SPK_B) + signature
 - Bob's one-time prekey (OPK_B), if available

2. Alice verifies SPK_B signature using Bob's Ed25519 identity key

3. Alice generates ephemeral keypair (EK_A)

4. Four DH operations:
 DH1 = X25519(IK_A_private, SPK_B) # Alice identity x Bob signed prekey
 DH2 = X25519(EK_A_private, IK_B) # Alice ephemeral x Bob identity
 DH3 = X25519(EK_A_private, SPK_B) # Alice ephemeral x Bob signed prekey
 DH4 = X25519(EK_A_private, OPK_B) # Alice ephemeral x Bob one-time prekey
 # (only if OPK available)

5. Concatenate: key_material = DH1 || DH2 || DH3 [|| DH4]

6. Derive shared key via HKDF-SHA256:
 shared_key = HKDF(
 salt = 0x00 * 32,
 ikm = 0xFF * 32 || key_material,
 info = "X3DH",
 length = 32
 )

7. Return: shared_key, associated_data (IK_A_pub || IK_B_pub), EK_A_pub
```

The `0xFF * 32` prefix before the key material is a domain separator. This matches the Signal specification and prevents potential cross-protocol attacks.

**DoubleRatchet** (`frontend/src/crypto/double-ratchet.ts`) handles:
- Sender initialization from X3DH shared secret (`frontend/src/crypto/double-ratchet.ts`)
- Receiver initialization (`frontend/src/crypto/double-ratchet.ts`)
- Message encryption with chain key advancement (`frontend/src/crypto/double-ratchet.ts`)
- Message decryption with out-of-order support (`frontend/src/crypto/double-ratchet.ts`)
- DH ratchet steps for forward secrecy (`frontend/src/crypto/double-ratchet.ts`)
- Skipped message key storage for out-of-order delivery (`frontend/src/crypto/double-ratchet.ts`)

The ratchet uses two KDF chains:

```
Root Key Chain:
 _kdf_rk(root_key, dh_output) → (new_root_key, new_chain_key)
 Uses HKDF-SHA256 with root_key as salt (frontend/src/crypto/double-ratchet.ts)

Symmetric Key Chain:
 _kdf_ck(chain_key) → (next_chain_key, message_key)
 Uses HMAC-SHA256 with 0x01 for chain key, 0x02 for message key
 (frontend/src/crypto/double-ratchet.ts)
```

Each message is encrypted with AES-256-GCM using a 12-byte random nonce (`frontend/src/crypto/double-ratchet.ts`). The message key is derived from the sending chain and used exactly once. After encryption, the sending chain advances, and the old message key is discarded.

**Security limits from `config.py`:**
- `MAX_SKIP_MESSAGE_KEYS = 1000` : Maximum messages that can arrive out of order before the protocol rejects them
- `MAX_CACHED_MESSAGE_KEYS = 2000` : Maximum stored skipped keys before eviction
- `AES_GCM_NONCE_SIZE = 12` : 96-bit nonces for AES-GCM
- `HKDF_OUTPUT_SIZE = 32` : 256-bit derived keys

**Client-side crypto:** The frontend `primitives.ts` mirrors the backend crypto using the WebCrypto API. It provides:
- `generateX25519KeyPair`
- `x25519DeriveSharedSecret`
- `generateEd25519KeyPair`
- `ed25519Sign` / `ed25519Verify` (lines 99, 113)
- `hkdfDerive` / `hkdfDeriveKey` (lines 166, 194)
- `aesGcmEncrypt` / `aesGcmDecrypt` (lines 224, 261)
- `hmacSha256` / `hmacSha256Verify` (lines 310, 329)
- `constantTimeEqual` : Constant-time comparison to prevent timing side channels

The client also has `crypto-service.ts`, `double-ratchet.ts`, `x3dh.ts`, `key-store.ts`, and `message-store.ts` which orchestrate these primitives into the full protocol flows.

**One encryption path: client-side, server is opaque.**

`MessageService` (`backend/app/services/message_service.py`) exposes a single method, `store_encrypted_message`, which receives `ciphertext`, `nonce`, and `header` as opaque strings and writes them straight into SurrealDB. The server has no decryption helper and no ratchet state — it literally cannot read messages because it never has the keys.

---

### Authentication System

**Purpose:** Passwordless authentication using WebAuthn/FIDO2 passkeys.

**Key Files:** `core/passkey/passkey_manager.py`, `api/auth.py`, `services/auth_service.py`, `core/redis_manager.py`

The `PasskeyManager` (`backend/app/core/passkey/passkey_manager.py`) wraps the `py_webauthn` library. It is configured with the Relying Party (RP) settings from `config.py`:

```python
self.rp_id = settings.RP_ID # e.g., "localhost" or "chat.example.com"
self.rp_name = settings.RP_NAME # "Encrypted P2P Chat"
self.rp_origin = settings.RP_ORIGIN # "https://chat.example.com"
```

**Registration flow:**

```
Client Server Redis
 │ │ │
 │ POST /auth/register/begin│ │
 │ { username, display_name }│ │
 │ ─────────────────────────►│ │
 │ │ │
 │ PasskeyManager.generate_registration_options
 │ (backend/app/core/passkey/passkey_manager.py) │
 │ │ │
 │ │ SET webauthn:reg_challenge:{username}
 │ │ challenge_bytes, TTL=600s│
 │ │ ──────────────────────────►
 │ │ │
 │ ◄─── registration options (publicKey config) ────────│
 │ │ │
 │ Browser WebAuthn API │ │
 │ navigator.credentials │ │
 │ .create(options) │ │
 │ User touches │ │
 │ authenticator │ │
 │ │ │
 │ POST /auth/register/complete │
 │ { credential, username } │ │
 │ ─────────────────────────►│ │
 │ │ │
 │ │ GET+DEL webauthn:reg_challenge:{username}
 │ │ ──────────────────────────►
 │ │ ◄── challenge_bytes ──────│
 │ │ │
 │ PasskeyManager.verify_registration │
 │ (backend/app/core/passkey/passkey_manager.py) │
 │ │ │
 │ Create User in PostgreSQL │
 │ Store Credential in PostgreSQL │
 │ Initialize X3DH keys │
 │ (backend/app/services/prekey_service.py) │
 │ │ │
 │ ◄─── UserResponse (id, username, etc.) ──────────────│
```

**Authentication flow:**

The authentication flow is similar but uses `generate_authentication_options` and `verify_authentication`. A critical detail is the signature counter check (`backend/app/core/passkey/passkey_manager.py`): if the new counter is not greater than the stored counter, it raises a `ValueError` indicating a potentially cloned authenticator. This is the WebAuthn clone detection mechanism.

**Challenge storage:** Redis stores challenges with a 600-second TTL (`WEBAUTHN_CHALLENGE_TTL_SECONDS = 600`, `config.py`). The `get_registration_challenge` and `get_authentication_challenge` methods use Redis pipelines to atomically GET and DELETE the challenge (`redis_manager.py`). This ensures each challenge is used exactly once.

The challenge itself is 32 random bytes (`WEBAUTHN_CHALLENGE_BYTES = 32`, `config.py`), stored as hex in Redis.

**Auth endpoints** (`auth.py`):

| Endpoint | Method | Status | Description |
|---|---|---|---|
| `/auth/register/begin` | POST | 200 | Generate WebAuthn registration options |
| `/auth/register/complete` | POST | 201 | Verify credential, create user + keys |
| `/auth/authenticate/begin` | POST | 200 | Generate WebAuthn authentication options |
| `/auth/authenticate/complete` | POST | 200 | Verify credential, update counter |
| `/auth/users/search` | POST | 200 | Search users by username/display name |

---

### Database Layer

**Purpose:** Persistent storage split across three purpose-built databases.

**PostgreSQL via SQLModel/SQLAlchemy async:** Handles all relational data with ACID guarantees.

The engine is configured in `models/Base.py`:

```python
engine = create_async_engine(
 str(settings.DATABASE_URL), # postgresql+asyncpg://...
 echo = settings.DEBUG, # SQL logging in development
 pool_size = settings.DB_POOL_SIZE, # 20 (config.py)
 max_overflow = settings.DB_MAX_OVERFLOW, # 40 (config.py)
 pool_pre_ping = True, # Detect stale connections
)
```

The session factory (`Base.py`) creates `AsyncSession` instances with `expire_on_commit=False` so that objects remain usable after commit without requiring a refresh.

**SurrealDB via AsyncSurreal:** Handles real-time messaging data. The `SurrealDBManager` (`surreal_manager.py`) connects over WebSocket to SurrealDB and provides methods for message CRUD, room management, presence tracking, and live query subscriptions. The live query feature is the primary reason SurrealDB was chosen: it pushes new records to subscribers in real-time, eliminating the need for polling.

**Redis via redis.asyncio:** Handles ephemeral data. The `RedisManager` (`redis_manager.py`) uses a connection pool of 50 connections (`redis_manager.py`) and stores challenges as hex-encoded bytes with TTL-based expiry.

---

## Data Flow

### Primary Flow: Sending an Encrypted Message

This is the most important flow in the system. Here is what happens step by step when Alice sends a message to Bob, assuming they already have an established Double Ratchet session:

```
Alice's Browser Server Bob's Browser
 │ │ │
 ┌────┴────────────────┐ │ │
 │ 1. User types msg │ │ │
 │ in ChatInput.tsx │ │ │
 └────┬────────────────┘ │ │
 │ │ │
 ┌────┴────────────────┐ │ │
 │ 2. crypto-service.ts│ │ │
 │ encrypts: │ │ │
 │ a. Advance send │ │ │
 │ chain via │ │ │
 │ HMAC-SHA256 │ │ │
 │ b. Derive unique │ │ │
 │ message key │ │ │
 │ c. AES-256-GCM │ │ │
 │ encrypt with │ │ │
 │ random nonce │ │ │
 │ d. Build header: │ │ │
 │ {dh_pub_key, │ │ │
 │ msg_number, │ │ │
 │ prev_chain} │ │ │
 └────┬────────────────┘ │ │
 │ │ │
 │ 3. WebSocket send: │ │
 │ { │ │
 │ type: "encrypted_message", │
 │ recipient_id: bob_uuid, │ │
 │ room_id: room_uuid, │ │
 │ ciphertext: "base64...",│ │
 │ nonce: "base64...", │ │
 │ header: "{...json...}", │ │
 │ temp_id: "client_123" │ │
 │ } │ │
 │ ───────────────────────────► │
 │ │ │
 │ ┌────────────┴───────────────┐ │
 │ │ 4. websocket.py │ │
 │ │ receives JSON, parses │ │
 │ │ routes via │ │
 │ │ websocket_service │ │
 │ └────────────┬───────────────┘ │
 │ │ │
 │ ┌────────────┴───────────────┐ │
 │ │ 5. websocket_service.py: │ │
 │ │ handle_encrypted_message│ │
 │ │ │ │
 │ │ Extracts fields, │ │
 │ │ opens DB session │ │
 │ └────────────┬───────────────┘ │
 │ │ │
 │ ┌────────────┴───────────────┐ │
 │ │ 6. message_service.py: │ │
 │ │ store_encrypted_message │ │
 │ │ │ │
 │ │ Looks up sender user │ │
 │ │ for username. │ │
 │ │ Stores ciphertext, │ │
 │ │ nonce, header AS-IS in │ │
 │ │ SurrealDB. │ │
 │ │ NO DECRYPTION. │ │
 │ └────────────┬───────────────┘ │
 │ │ │
 │ ┌────────────┴───────────────┐ │
 │ │ 7. SurrealDB live query │ │
 │ │ fires for Bob because │ │
 │ │ recipient_id matches │ │
 │ └────────────┬───────────────┘ │
 │ │ │
 │ ┌────────────┴───────────────┐ │
 │ │ 8. websocket_manager.py: │ │
 │ │ _handle_live_message │ │
 │ │ │ │
 │ │ Wraps as EncryptedMsgWS │ │
 │ └────────────┬───────────────┘ │
 │ │ │
 │ ┌────────────┴───────────────┐ │
 │ │ 9. send_message(bob_uuid) │ │
 │ │ │ │
 │ │ Sends to ALL of Bob's │ │
 │ │ active WebSockets │ │
 │ └────────────┬───────────────┘ │
 │ │ ─────────────────────────────►
 │ │ │
 │ │ ┌────────────────┴──┐
 │ │ │ 10. Bob's crypto- │
 │ │ │ service.ts │
 │ │ │ decrypts: │
 │ │ │ a. Check for │
 │ │ │ skipped │
 │ │ │ msg keys │
 │ │ │ b. If new DH │
 │ │ │ pub key, │
 │ │ │ DH ratchet │
 │ │ │ step │
 │ │ │ c. Advance │
 │ │ │ recv chain │
 │ │ │ d. Derive msg │
 │ │ │ key │
 │ │ │ e. AES-256-GCM│
 │ │ │ decrypt │
 │ │ └────────┬─────────┘
 │ │ │
 │ │ ┌────────┴─────────┐
 │ │ │ 11. Plaintext │
 │ │ │ rendered in │
 │ │ │ MessageList │
 │ │ └──────────────────┘
 │ │ │
 │ ◄── confirmation ─────────│ │
 │ { type: "message_sent", │ │
 │ temp_id: "client_123", │ │
 │ status: "sent" } │ │
```

The server never sees the plaintext. It acts purely as a relay that stores and forwards ciphertext blobs. The `store_encrypted_message` method (`backend/app/services/message_service.py`) literally just wraps the received fields into a dict and calls `surreal_db.create_message`.

The confirmation message sent back to Alice (`backend/app/services/websocket_service.py`) includes the `temp_id` so the client can match it to the optimistically rendered message in the UI.

---

### Secondary Flow: New User Registration + Key Setup

This flow happens once per user.

```
Step 1: POST /auth/register/begin
 backend/app/services/auth_service.py
 → PasskeyManager generates challenge
 → Challenge stored in Redis with 600s TTL
 → Registration options returned to client

Step 2: Browser WebAuthn API (navigator.credentials.create)
 → User interacts with authenticator (Touch ID, YubiKey, etc.)
 → Browser creates credential bound to RP origin

Step 3: POST /auth/register/complete
 backend/app/services/auth_service.py
 → Challenge retrieved from Redis (GET+DEL atomic)
 → PasskeyManager verifies credential against challenge
 → User record created in PostgreSQL
 → Credential record created in PostgreSQL
 → prekey_service.initialize_user_keys called
 (backend/app/services/prekey_service.py)

Step 4: Server-side key initialization (backend/app/services/prekey_service.py)
 → Generate X25519 identity keypair (IK)
 → Generate Ed25519 signing keypair
 → Store both public+private in PostgreSQL identity_keys table
 → Generate signed prekey (SPK) signed with Ed25519 IK
 → Generate 100 one-time prekeys (OPKs)
 → Store all in PostgreSQL

Step 5: (Client-side, post-registration)
 Client generates its own X3DH keys using WebCrypto:
 → X25519 identity keypair
 → Ed25519 signing keypair
 → Signed prekey with signature
 → 100 one-time prekeys

Step 6: POST /encryption/upload-keys/{user_id}
 backend/app/api/encryption.py
 → prekey_service.store_client_keys
 (backend/app/services/prekey_service.py)
 → Only PUBLIC keys stored on server
 → Private keys remain in browser IndexedDB
```

Note there is a dual path here. Step 4 is the server-side key generation (used as a fallback and for backwards compatibility). Step 5-6 is the client-side key generation path (the preferred production path). In the client-side path, the server never sees private keys.

---

### Secondary Flow: Establishing a New Chat Session (X3DH)

When Alice wants to message Bob for the first time:

```
Step 1: Alice's client requests Bob's prekey bundle
 GET /encryption/prekey-bundle/{bob_id}
 backend/app/api/encryption.py

Step 2: prekey_service.get_prekey_bundle(session, bob_id)
 backend/app/services/prekey_service.py
 → Fetch Bob's identity key (IK)
 → Fetch Bob's active signed prekey (SPK)
 → If no active SPK, auto-rotate (backend/app/services/prekey_service.py)
 → Fetch one unused one-time prekey (OPK)
 → Mark OPK as used (single-use guarantee,)
 → If unused OPK count < 20, auto-replenish 100 more
 (backend/app/api/encryption.py)
 → Return PreKeyBundle{IK, IK_ed25519, SPK, SPK_sig, OPK}

Step 3: Alice performs X3DH sender-side locally
 Using the prekey bundle and her own identity key:
 a. Verify SPK signature with Bob's Ed25519 IK
 b. Generate ephemeral keypair (EK)
 c. Compute DH1..DH4
 d. Derive shared_key via HKDF

Step 4: Initialize Double Ratchet with shared_key
 Alice's client calls double_ratchet.initialize_sender
 with the shared key and Bob's SPK as the initial peer key

Step 5: First message includes X3DH header
 The header contains Alice's ephemeral public key and
 identity key reference so Bob can derive the same
 shared secret when he comes online

Step 6: Bob receives the message
 Bob's client uses the X3DH header + his own private keys
 to perform the receiver-side X3DH exchange
 (frontend/src/crypto/x3dh.ts)
 Both parties now share the same root key for the
 Double Ratchet
```

The OPK single-use guarantee is enforced at the database level. When `get_prekey_bundle` fetches an OPK, it immediately marks `is_used = True` and commits (`backend/app/services/prekey_service.py`). If someone else requests the same OPK concurrently, they will get a different one or none.

---

## Design Patterns

### Application Factory Pattern

**Where:** `factory.py`

**Why:** The `create_app` function builds and returns a fully configured FastAPI instance. This separates app creation from app execution (`main.py` just calls `create_app`). The practical benefit is testability: you can call `create_app` with different configurations in tests without starting a server. The lifespan manager (`factory.py`) ensures all databases are connected before the first request and properly disconnected on shutdown.

### Service Layer Pattern

**Where:** `services/` directory (auth_service.py, prekey_service.py, message_service.py, presence_service.py, websocket_service.py)

**Why:** Business logic lives in service classes, not in API endpoint functions. The API layer (`api/`) is thin: it handles request validation and response formatting, then delegates to services. Services are stateless singletons instantiated at module level:

```python
message_service = MessageService # backend/app/services/message_service.py
prekey_service = PrekeyService # backend/app/services/prekey_service.py
auth_service = AuthService # backend/app/services/auth_service.py
websocket_service = WebSocketService # backend/app/services/websocket_service.py
```

This means any endpoint can import and call any service without worrying about instantiation or dependency injection. The tradeoff is that services cannot be easily swapped at runtime, but for this application that is not needed.

### Connection Pool Pattern

**Where:** `websocket_manager.py`

**Why:** The `ConnectionManager` maps user IDs to lists of WebSocket connections. This supports multiple simultaneous devices per user (up to 5, enforced at `websocket_manager.py`). When a message needs to be delivered, `send_message` iterates over all connections for that user. Dead connections are detected during send attempts and cleaned up immediately.

### Observer Pattern (Live Queries)

**Where:** `websocket_manager.py`, `surreal_manager.py`

**Why:** SurrealDB live queries implement a push-based notification system. When a new message is created in SurrealDB with `recipient_id = bob`, SurrealDB pushes that record to the server through the live query callback. The server then forwards it to Bob's WebSocket connections. This eliminates polling entirely. The alternative would be the server polling SurrealDB for new messages, which would add latency proportional to the polling interval and waste resources when no messages are pending.

The subscription is per-user, not per-room. `live_messages_for_user` (`surreal_manager.py`) watches `WHERE recipient_id = '{user_id}'`, so the server receives all messages destined for that user regardless of room.

### Singleton Pattern

**Where:** Module-level instances at the bottom of each manager file:

```python
passkey_manager = PasskeyManager # backend/app/core/passkey/passkey_manager.py
connection_manager = ConnectionManager # backend/app/core/websocket_manager.py
surreal_db = SurrealDBManager # backend/app/core/surreal_manager.py
redis_manager = RedisManager # backend/app/core/redis_manager.py
```

**Why:** These managers either hold no per-request state (`PasskeyManager` holds only the RP configuration) or manage shared connection pools (`surreal_db`, `redis_manager`, `connection_manager`). A single instance per process is the correct model. The X3DH and Double Ratchet implementations live in the browser as plain TypeScript modules — there is no server-side counterpart that needs a singleton.

---

## Layer Separation

```
┌─────────────────────────────────────────────────────────────────┐
│ API Layer (api/) │
│ ┌───────────┐ ┌──────────────┐ ┌─────────┐ ┌──────────────┐ │
│ │ auth.py │ │ encryption.py│ │ rooms.py│ │ websocket.py │ │
│ │ lines │ │ lines 1-127 │ │ │ │ lines 1-85 │ │
│ │ 1-104 │ │ │ │ │ │ │ │
│ └───────────┘ └──────────────┘ └─────────┘ └──────────────┘ │
│ HTTP/WS endpoints. Request validation. Response formatting. │
│ Thin wrappers that delegate to services. │
├─────────────────────────────────────────────────────────────────┤
│ Service Layer (services/) │
│ ┌──────────────┐ ┌───────────────┐ ┌─────────────────────┐ │
│ │ auth_service │ │ prekey_service│ │ message_service │ │
│ │ lines 1-601 │ │ lines 1-468 │ │ lines 1-469 │ │
│ └──────────────┘ └───────────────┘ └─────────────────────┘ │
│ ┌──────────────────┐ ┌──────────────────┐ │
│ │ presence_service │ │ websocket_service│ │
│ └──────────────────┘ └──────────────────┘ │
│ Business logic. Orchestration. Error handling. │
│ Stateless singletons. Import Core + Models. │
├─────────────────────────────────────────────────────────────────┤
│ Core Layer (core/) │
│ ┌─────────────────────┐ ┌─────────────────┐ │
│ │ passkey_manager │ │ dependencies │ │
│ │ (WebAuthn ceremony) │ │ (current_user) │ │
│ └─────────────────────┘ └─────────────────┘ │
│ ┌──────────────────┐ ┌──────────────┐ ┌──────────────────┐ │
│ │ websocket_manager│ │ surreal_mgr │ │ redis_manager │ │
│ │ (connection pool)│ │ (live query) │ │ (sessions+chal.) │ │
│ └──────────────────┘ └──────────────┘ └──────────────────┘ │
│ ┌──────────────────┐ ┌──────────────────────────────────┐ │
│ │ exceptions.py │ │ exception_handlers.py │ │
│ └──────────────────┘ └──────────────────────────────────┘ │
│ Database clients. WebSocket pool. Auth dependencies. │
│ No server-side cryptography lives here — that's the client. │
│ No imports from API or Services. │
├─────────────────────────────────────────────────────────────────┤
│ Model Layer (models/) │
│ ┌──────┐ ┌────────────┐ ┌─────────────┐ ┌──────────────┐ │
│ │ User │ │ Credential │ │ IdentityKey │ │ SignedPrekey │ │
│ └──────┘ └────────────┘ └─────────────┘ └──────────────┘ │
│ ┌──────────────┐ │
│ │ OneTimePrekey│ Public-only prekey material — no privates. │
│ └──────────────┘ │
│ SQLModel ORM classes. Data structures. Validation. │
│ Import only config constants and Base. │
├─────────────────────────────────────────────────────────────────┤
│ Schema Layer (schemas/) │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
│ │ auth.py │ │ common.py│ │ rooms.py │ │ websocket.py │ │
│ └──────────┘ └──────────┘ └──────────┘ └──────────────────┘ │
│ ┌──────────────┐ │
│ │ surreal.py │ │
│ └──────────────┘ │
│ Pydantic request/response models. API contracts. │
│ Serialization. No business logic. │
└─────────────────────────────────────────────────────────────────┘
```

**Import rules:** API imports Services. Services import Core + Models. Core imports nothing from API or Services. Models import nothing except config constants and the Base class. Schemas import nothing except config constants.

The only exception is `websocket_service.py`, which imports `connection_manager` from Core and `message_service` from Services. This is acceptable because WebSocket message handling straddles both layers.

---

## Data Models

### PostgreSQL Schema (Auth + Keys)

All PostgreSQL models inherit from `BaseDBModel` (`models/Base.py`), which provides `created_at` and `updated_at` timestamp fields with timezone awareness.

**users** (`models/User.py`)

```
┌────────────────────────────────────────────────────────────┐
│ users │
├──────────────────────┬──────────────────┬──────────────────┤
│ Column │ Type │ Constraints │
├──────────────────────┼──────────────────┼──────────────────┤
│ id │ UUID │ PK, default uuid4│
│ username │ VARCHAR(50) │ UNIQUE, INDEX │
│ display_name │ VARCHAR(100) │ NOT NULL │
│ is_active │ BOOLEAN │ default True │
│ is_verified │ BOOLEAN │ default False │
│ identity_key │ VARCHAR(500) │ nullable │
│ signed_prekey │ VARCHAR(500) │ nullable │
│ signed_prekey_sig │ VARCHAR(500) │ nullable │
│ one_time_prekeys │ TEXT │ nullable │
│ created_at │ TIMESTAMP(tz) │ NOT NULL │
│ updated_at │ TIMESTAMP(tz) │ NOT NULL │
├──────────────────────┴──────────────────┴──────────────────┤
│ Relationships: credentials (1:many → Credential) │
└────────────────────────────────────────────────────────────┘
```

**credentials** (`models/Credential.py`)

```
┌────────────────────────────────────────────────────────────┐
│ credentials │
├──────────────────────┬──────────────────┬──────────────────┤
│ Column │ Type │ Constraints │
├──────────────────────┼──────────────────┼──────────────────┤
│ id │ INTEGER │ PK, autoincrement│
│ credential_id │ VARCHAR(512) │ UNIQUE, INDEX │
│ public_key │ VARCHAR(1024) │ NOT NULL │
│ sign_count │ INTEGER │ default 0 │
│ aaguid │ VARCHAR(64) │ nullable │
│ backup_eligible │ BOOLEAN │ default False │
│ backup_state │ BOOLEAN │ default False │
│ attestation_type │ VARCHAR(50) │ nullable │
│ transports │ VARCHAR(200) │ nullable │
│ user_id │ UUID │ FK → users.id │
│ device_name │ VARCHAR(100) │ nullable │
│ last_used_at │ TIMESTAMP(tz) │ nullable │
│ created_at │ TIMESTAMP(tz) │ NOT NULL │
│ updated_at │ TIMESTAMP(tz) │ NOT NULL │
├──────────────────────┴──────────────────┴──────────────────┤
│ Relationships: user (many:1 → User) │
└────────────────────────────────────────────────────────────┘
```

**identity_keys** (`backend/app/models/IdentityKey.py`)

```
┌────────────────────────────────────────────────────────────┐
│ identity_keys │
├──────────────────────┬──────────────────┬──────────────────┤
│ Column │ Type │ Constraints │
├──────────────────────┼──────────────────┼──────────────────┤
│ id │ INTEGER │ PK, autoincrement│
│ user_id │ UUID │ FK → users.id │
│ │ │ UNIQUE, INDEX │
│ public_key │ VARCHAR(64) │ NOT NULL (X25519)│
│ public_key_ed25519 │ VARCHAR(64) │ NOT NULL │
│ created_at │ TIMESTAMP(tz) │ NOT NULL │
│ updated_at │ TIMESTAMP(tz) │ NOT NULL │
└────────────────────────────────────────────────────────────┘
```

Public-only. The server never stores identity private keys — those live exclusively in the client's IndexedDB.

**signed_prekeys** (`backend/app/models/SignedPrekey.py`)

```
┌────────────────────────────────────────────────────────────┐
│ signed_prekeys │
├──────────────────────┬──────────────────┬──────────────────┤
│ Column │ Type │ Constraints │
├──────────────────────┼──────────────────┼──────────────────┤
│ id │ INTEGER │ PK, autoincrement│
│ user_id │ UUID │ FK → users.id │
│ key_id │ INTEGER │ INDEX │
│ public_key │ VARCHAR(64) │ NOT NULL (X25519)│
│ signature │ VARCHAR(128) │ NOT NULL (Ed25519)│
│ is_active │ BOOLEAN │ default True │
│ expires_at │ TIMESTAMP(tz) │ nullable │
│ created_at │ TIMESTAMP(tz) │ NOT NULL │
│ updated_at │ TIMESTAMP(tz) │ NOT NULL │
└────────────────────────────────────────────────────────────┘
```

Rotation: the client generates a new signed prekey roughly every 48 hours (`SIGNED_PREKEY_ROTATION_HOURS`) and re-runs `uploadKeys` to publish the new public + signature. The previous active SPK is marked `is_active=False` by `store_client_keys` so the bundle endpoint always serves the latest.

**one_time_prekeys** (`backend/app/models/OneTimePrekey.py`)

```
┌────────────────────────────────────────────────────────────┐
│ one_time_prekeys │
├──────────────────────┬──────────────────┬──────────────────┤
│ Column │ Type │ Constraints │
├──────────────────────┼──────────────────┼──────────────────┤
│ id │ INTEGER │ PK, autoincrement│
│ user_id │ UUID │ FK → users.id │
│ key_id │ INTEGER │ INDEX │
│ public_key │ VARCHAR(64) │ NOT NULL (X25519)│
│ is_used │ BOOLEAN │ default False │
│ │ │ INDEX │
│ created_at │ TIMESTAMP(tz) │ NOT NULL │
│ updated_at │ TIMESTAMP(tz) │ NOT NULL │
└────────────────────────────────────────────────────────────┘
```

The client uploads OPK publics in batches of 100 (`DEFAULT_ONE_TIME_PREKEY_COUNT` in `frontend/src/types/encryption.ts`) and re-uploads when its local unused-OPK count drops below half. When `get_prekey_bundle` hands one out, it sets `is_used=True` so the same OPK is never offered to two senders.

> Note: there are no `ratchet_states` or `skipped_message_keys` tables. The Double Ratchet — including its skipped-key cache — runs entirely in the browser and is persisted in IndexedDB by `frontend/src/crypto/key-store.ts:saveRatchetState`. Putting that state on the server would mean the server held the symmetric keys, defeating E2EE.
│ created_at │ TIMESTAMP(tz) │ NOT NULL │
│ updated_at │ TIMESTAMP(tz) │ NOT NULL │
└────────────────────────────────────────────────────────────┘
```

These store message keys for out-of-order delivery. When the receiving ratchet advances past a message number that has not been received yet, the key for that message is computed and stored here. When the skipped message eventually arrives, its key is looked up and consumed.

### SurrealDB Schema (Messages + Presence)

SurrealDB is schemaless, but these are the document structures the application creates:

**messages** (created via `surreal_manager.py`)

```
{
 id: "messages:ulid_here", // SurrealDB auto-generated
 sender_id: "uuid_string",
 recipient_id: "uuid_string",
 room_id: "rooms:ulid_here" | null,
 ciphertext: "base64url_encoded_bytes",
 nonce: "base64url_encoded_bytes",
 header: "{\"dh_public_key\":\"...\",\"message_number\":0,...}",
 sender_username: "alice",
 created_at: "2026-01-15T10:30:00Z",
 updated_at: "2026-01-15T10:30:00Z"
}
```

**presence** (created via `surreal_manager.py`)

```
{
 id: "presence:`user_uuid`", // user-specific record ID
 user_id: "uuid_string",
 status: "online" | "away" | "offline",
 last_seen: "2026-01-15T10:30:00Z",
 updated_at: "time::now"
}
```

**rooms** (created via `surreal_manager.py`)

```
{
 id: "rooms:ulid_here",
 name: "Room Name",
 type: "direct" | "group",
 members: ["uuid1", "uuid2"],
 created_at: "2026-01-15T10:30:00Z",
 updated_at: "2026-01-15T10:30:00Z"
}
```

**room_participants** (created via `surreal_manager.py`)

```
{
 id: "room_participants:ulid_here",
 room_id: "rooms:ulid_here",
 user_id: "uuid_string",
 role: "member" | "admin",
 joined_at: "2026-01-15T10:30:00Z"
}
```

### Redis Keys

```
webauthn:reg_challenge:{username} → 32 bytes (hex-encoded), TTL 600s
webauthn:auth_challenge:{username} → 32 bytes (hex-encoded), TTL 600s
```

These are the only two key patterns currently in use. Both use the Redis pipeline GET+DELETE pattern (`redis_manager.py`) for atomic one-time consumption. The TTL ensures stale challenges are automatically cleaned up even if the client never completes the flow.

---

## Security Architecture

### Threat Model

**What the system protects against:**

| Threat | Protection | How |
|---|---|---|
| Compromised server | E2E encryption | Server stores ciphertext, never has keys |
| Network eavesdropper | TLS + E2E | Even without TLS, messages are AES-256-GCM encrypted |
| Stolen database dump | Key separation | PostgreSQL has public keys only (client-side path). Private keys live in browser IndexedDB. OPKs are single-use. |
| Phishing / credential theft | WebAuthn | Credentials are origin-bound. Cannot be replayed on a different domain. |
| Replay attacks | Nonces + counters | AES-GCM nonces are random. Message numbers are sequential. WebAuthn challenges have TTL. |
| Authenticator cloning | Signature counter | `backend/app/core/passkey/passkey_manager.py` checks that the counter strictly increases. If it does not, authentication fails with a clone detection error. |
| Message tampering | AEAD | AES-256-GCM provides authenticated encryption. Tampered ciphertext fails the GCM tag check (`frontend/src/crypto/double-ratchet.ts`). |
| Key compromise (single key) | Forward secrecy | Double Ratchet generates new DH keys regularly. Compromising one chain key reveals only future messages in that chain, not past messages. |

**What is out of scope:**

| Threat | Why |
|---|---|
| Compromised client device | If the attacker has access to the browser, they have access to IndexedDB (private keys) and can read plaintext. There is no defense against a fully compromised endpoint. |
| Side-channel attacks on crypto | The `constantTimeEqual` function in `frontend/src/crypto/primitives.ts` is the extent of timing attack mitigation. Comprehensive side-channel resistance would require constant-time implementations of all crypto primitives, which the WebCrypto API generally provides but does not guarantee. |
| Metadata analysis | The server knows who messages whom, when, how often, and message sizes. Only content is protected, not metadata. Protecting metadata would require something like mixnets or onion routing, which is not implemented. |
| Quantum computing | X25519 and Ed25519 are not post-quantum. A sufficiently powerful quantum computer could break them. Post-quantum key exchange (e.g., ML-KEM/Kyber) is not implemented. |
| Compromised authenticator supply chain | If the authenticator hardware itself is backdoored, WebAuthn cannot detect this. The AAGUID field can identify the authenticator model but not verify its integrity. |

### Defense in Depth

```
Layer 1: Transport Security (TLS/HTTPS via Nginx)
 │
 │ Protects: Data in transit between client and server
 │ Mechanism: TLS certificate, HTTPS enforcement
 │ Configuration: Nginx reverse proxy with SSL termination
 │
 ▼
Layer 2: Authentication (WebAuthn/Passkeys)
 │
 │ Protects: Identity verification, prevents impersonation
 │ Mechanism: Public-key cryptography, hardware-bound keys
 │ Key files: backend/app/core/passkey/passkey_manager.py, backend/app/services/auth_service.py
 │ Redis: Challenge storage with 600s TTL, one-time consumption
 │
 ▼
Layer 3: Key Exchange (X3DH Protocol)
 │
 │ Protects: Initial shared secret establishment
 │ Mechanism: 3-4 Diffie-Hellman operations + HKDF
 │ Key files: frontend/src/crypto/x3dh.ts, backend/app/services/prekey_service.py
 │ Properties: Asynchronous (works even if recipient offline)
 │ Deniable (either party could have forged the exchange)
 │
 ▼
Layer 4: Message Encryption (Double Ratchet + AES-256-GCM)
 │
 │ Protects: Message confidentiality and integrity
 │ Mechanism: Symmetric ratchet (HMAC chains) + DH ratchet
 │ Key files: frontend/src/crypto/double-ratchet.ts, frontend/src/crypto/primitives.ts
 │ Properties: Forward secrecy per-message
 │ Future secrecy (self-healing after compromise)
 │
 ▼
Layer 5: Key Lifecycle Management
 │
 │ Protects: Limits blast radius of any single key compromise
 │ Mechanism: SPK rotation every 48h, OPK single-use, old SPK cleanup
 │ Key files: backend/app/services/prekey_service.py (rotation),
 │ backend/app/services/prekey_service.py (cleanup),
 │ backend/app/services/prekey_service.py (replenishment)
 │ Constants: SIGNED_PREKEY_ROTATION_HOURS=48 (config.py)
 │ SIGNED_PREKEY_RETENTION_DAYS=7 (config.py)
 │ DEFAULT_ONE_TIME_PREKEY_COUNT=100 (config.py)
 │
 ▼
Layer 6: Rate Limiting and Abuse Prevention
 │
 Protects: Against brute force and DoS
 Mechanism: Per-user message rate limits, auth attempt limits
 Constants: RATE_LIMIT_MESSAGES_PER_MINUTE=60 (config.py)
 RATE_LIMIT_AUTH_ATTEMPTS=5 (config.py)
 WS_MAX_CONNECTIONS_PER_USER=5 (config.py)
```

---

## Configuration

All configuration lives in `config.py`. The `Settings` class inherits from `pydantic_settings.BaseSettings` and loads values from environment variables and the `.env` file.

### Application Settings

| Variable | Default | Description |
|---|---|---|
| `ENV` | `"development"` | `development`, `production`, or `testing` |
| `DEBUG` | `True` | Enables SQL echo logging, docs endpoints |
| `APP_NAME` | `"encrypted-p2p-chat"` | Application name in metadata |
| `SECRET_KEY` | (required) | Application secret, no default |

### PostgreSQL Settings

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_HOST` | `"localhost"` | Database host |
| `POSTGRES_PORT` | `5432` | Database port |
| `POSTGRES_DB` | `"chat_auth"` | Database name |
| `POSTGRES_USER` | `"chat_user"` | Database user |
| `POSTGRES_PASSWORD` | `""` | Database password |
| `DATABASE_URL` | (auto-built) | Full connection string, assembled by `field_validator` |
| `DB_POOL_SIZE` | `20` | SQLAlchemy connection pool size |
| `DB_MAX_OVERFLOW` | `40` | Pool overflow connections |

The `assemble_db_connection` validator (`config.py`) builds the URL from components if `DATABASE_URL` is not explicitly set. The URL uses the `postgresql+asyncpg://` scheme for async connections.

### SurrealDB Settings

| Variable | Default | Description |
|---|---|---|
| `SURREAL_HOST` | `"localhost"` | SurrealDB host |
| `SURREAL_PORT` | `8000` | SurrealDB port |
| `SURREAL_USER` | `"root"` | SurrealDB user |
| `SURREAL_PASSWORD` | (required) | SurrealDB password |
| `SURREAL_NAMESPACE` | `"chat"` | SurrealDB namespace |
| `SURREAL_DATABASE` | `"production"` | SurrealDB database |
| `SURREAL_URL` | (auto-built) | WebSocket URL, assembled |

### Redis Settings

| Variable | Default | Description |
|---|---|---|
| `REDIS_HOST` | `"localhost"` | Redis host |
| `REDIS_PORT` | `6379` | Redis port |
| `REDIS_PASSWORD` | `""` | Redis password (optional) |
| `REDIS_URL` | (auto-built) | Connection URL, assembled |

### WebAuthn Settings

| Variable | Default | Description |
|---|---|---|
| `RP_ID` | `"localhost"` | Relying Party ID (domain) |
| `RP_NAME` | `"Encrypted P2P Chat"` | Relying Party display name |
| `RP_ORIGIN` | `"http://localhost:3000"` | Expected origin for credential verification |

The `RP_ID` must match the domain the browser sees. In production, this would be `"chat.example.com"`. If it does not match, WebAuthn verification fails.

### WebSocket and Security Settings

| Variable | Default | Description |
|---|---|---|
| `WS_HEARTBEAT_INTERVAL` | `30` | Seconds between heartbeat pings |
| `WS_MAX_CONNECTIONS_PER_USER` | `5` | Max simultaneous WebSocket connections |
| `KEY_ROTATION_DAYS` | `90` | General key rotation period |
| `MAX_SKIPPED_MESSAGE_KEYS` | `1000` | Max out-of-order messages per ratchet |
| `RATE_LIMIT_MESSAGES_PER_MINUTE` | `60` | Per-user message rate limit |
| `RATE_LIMIT_AUTH_ATTEMPTS` | `5` | Max auth attempts before lockout |
| `CORS_ORIGINS` | `["http://localhost:3000", "http://localhost:5173"]` | Allowed CORS origins |

---

## Performance Considerations

### Database Connection Pooling

PostgreSQL pool: 20 base connections + 40 overflow = 60 max simultaneous connections (`config.py`). The engine uses `pool_pre_ping=True` (`models/Base.py`) to detect and replace stale connections before queries fail.

SQLAlchemy async sessions are created per-request via the `get_session` dependency (`models/Base.py`). Sessions are recycled automatically after each request.

Redis pool: 50 connections (`redis_manager.py`). Connection pooling is handled by `redis.asyncio.ConnectionPool`.

SurrealDB: Single persistent WebSocket connection per application instance (`surreal_manager.py`). The `ensure_connected` method (`surreal_manager.py`) lazily reconnects if the connection drops.

### Message Throughput

60 messages per minute per user rate limit (`config.py`). This translates to one message per second sustained, which is reasonable for a chat application.

WebSocket heartbeat every 30 seconds (`config.py`). This is frequent enough to detect dead connections quickly but not so frequent as to waste bandwidth on idle connections.

SurrealDB live queries are push-based (`surreal_manager.py`). When a new message is created, SurrealDB pushes it to the subscribed callback immediately. There is no polling interval, so latency is limited to network round-trip plus SurrealDB processing time.

### Encryption Overhead

Approximate per-message encryption cost (based on typical X25519/AES-256-GCM performance):

```
X25519 DH exchange: ~0.1ms
HMAC-SHA256 chain step: ~0.01ms
AES-256-GCM encrypt: ~0.001ms per KB (for typical chat messages)
HKDF derivation: ~0.01ms

Total per-message: < 1ms
```

This is negligible compared to network latency (typically 10-100ms). Encryption overhead is not a bottleneck for this application.

### Connection Limits

5 WebSocket connections per user (`config.py`). This supports a reasonable number of devices (phone, laptop, tablet, desktop, secondary browser) without allowing a single user to exhaust server WebSocket capacity.

The `ConnectionManager` delivers each message to all of a user's connections (`websocket_manager.py`), so the cost of multi-device scales linearly with the number of connections per user.

---

## Design Decisions

### Why Three Databases?

This is the most obvious question about the architecture, so it deserves a direct answer.

**PostgreSQL** stores relational data that requires ACID transactions: users with unique usernames, credentials with foreign keys to users, identity keys with unique constraints per user, ratchet states that must be updated atomically. This data has complex relationships (user has many credentials, ratchet state references two users, etc.) and benefits from SQL's referential integrity.

**SurrealDB** stores messages and presence data. The key feature is live queries: when a message is created, SurrealDB pushes it to subscribers in real-time without polling. This is the core of the chat experience. You could do this with PostgreSQL LISTEN/NOTIFY, but SurrealDB's live queries are more natural for this pattern and the schema is document-oriented, which fits the variable structure of encrypted messages better.

**Redis** stores ephemeral data that should auto-expire: WebAuthn challenges (600s TTL), rate limit counters. You would not want to poll PostgreSQL to clean up expired challenges. Redis handles this natively with key TTL.

The tradeoff is operational complexity. Running three databases means three things that can fail, three things to back up, three things to monitor. The justification is that each database is doing what it does best, and trying to make one database do all three jobs would create worse tradeoffs (e.g., polling for real-time updates, manual expiry jobs for challenges).

### Why WebAuthn Instead of JWT + Password?

WebAuthn passkeys are phishing-resistant by design. The credential is bound to the RP origin, so it cannot be used on a fake domain. There are no passwords to steal from a database breach. The private key never leaves the authenticator hardware.

The tradeoff is browser and device support. WebAuthn requires a modern browser and an authenticator (Touch ID, Windows Hello, YubiKey, etc.). Account recovery is harder: if you lose your only authenticator, you lose access. This can be mitigated by registering multiple authenticators.

### Why SolidJS Instead of React?

SolidJS uses fine-grained reactivity. When a message arrives, only the specific DOM elements that depend on that message are updated. React would diff the entire virtual DOM tree for the message list. For a real-time chat application where messages arrive frequently, this difference matters.

SolidJS also has a smaller bundle size than React, which helps with initial load time. The nanostores library provides a framework-agnostic reactive store that integrates naturally with SolidJS's reactivity model.

The tradeoff is ecosystem size. React has far more libraries, tutorials, and Stack Overflow answers. SolidJS is smaller and you occasionally need to build something that React would have a library for.

### Why Only a Client-Side Encryption Path?

An earlier draft of this project carried two encryption paths — a server-side one that loaded ratchet state from PostgreSQL and encrypted on the backend, and a client-side passthrough that stored opaque ciphertext. The audit (see `docs/plans/`) deleted the server-side path entirely, including its `RatchetState` and `SkippedMessageKey` tables and the entire `app/core/encryption/` Python module.

Why? Because as long as a server-side X3DH/Double Ratchet implementation exists, the schema columns it needs (private keys, ratchet roots) exist, and any caller can hit it — the server has the technical capability to read user messages. "Marked deprecated" is a comment, not a defense. The only way to honestly claim end-to-end encryption is to make it physically impossible for the server to participate. So now `message_service.py` has exactly one method, `store_encrypted_message`, and it does nothing but pass `ciphertext` / `nonce` / `header` through to SurrealDB.

---

## Deployment Architecture

### Development

```
docker compose -f dev.compose.yml up

┌───────────────────────────────────────────────────────────────┐
│ Docker Network (chat_network_dev) │
│ │
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ │
│ │ PostgreSQL │ │ SurrealDB │ │ Redis │ │
│ │ 16-alpine │ │ latest │ │ 8-alpine │ │
│ │ :5432→5432 │ │ :8000→8001 │ │ :6379→6379 │ │
│ │ │ │ file://data│ │ appendonly │ │
│ └─────────────┘ └─────────────┘ └─────────────┘ │
│ │
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ │
│ │ FastAPI │ │ Vite Dev │ │ Nginx │ │
│ │ :8000→8000 │ │ :5173→5173 │ │ :80→80 │ │
│ │ uvicorn │ │ HMR enabled│ │ reverse │ │
│ │ --reload │ │ hot module │ │ proxy │ │
│ │ vol: ./back │ │ vol: ./fro │ │ dev.nginx │ │
│ │ end │ │ ntend │ │ config │ │
│ └─────────────┘ └─────────────┘ └─────────────┘ │
│ │
│ Source: dev.compose.yml │
└───────────────────────────────────────────────────────────────┘
```

In development, all services expose ports to the host for direct access and debugging. The backend volume-mounts the `./backend` directory and runs with uvicorn `--reload` for live reloading. The frontend volume-mounts `./frontend` and runs Vite's dev server with HMR (Hot Module Replacement). Nginx sits in front as a reverse proxy matching the production topology.

### Production

```
docker compose up

┌───────────────────────────────────────────────────────────────┐
│ Docker Network (chat_network) │
│ │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ Nginx (:80, :443) │ │
│ │ │ │
│ │ /api/* ────────► upstream: backend:8000 (HTTP) │ │
│ │ /ws ────────► upstream: backend:8000 (WebSocket) │ │
│ │ /* ────────► Static SolidJS build (from image) │ │
│ │ │ │
│ └──────────────────────────┬───────────────────────────────┘ │
│ │ │
│ ┌──────────────────────────┼──────────────────────────────┐ │
│ │ │ │ │
│ │ ┌─────────────┐ ┌─────┴─────┐ ┌─────────────┐ │ │
│ │ │ PostgreSQL │ │ FastAPI │ │ SurrealDB │ │ │
│ │ │ 16-alpine │ │ gunicorn │ │ latest │ │ │
│ │ │ vol: data │ │ workers │ │ vol: data │ │ │
│ │ │ healthcheck │ │ no ports │ │ healthcheck│ │ │
│ │ │ restart: │ │ exposed │ │ restart: │ │ │
│ │ │ always │ │ to host │ │ always │ │ │
│ │ └─────────────┘ └───────────┘ └─────────────┘ │ │
│ │ │ │
│ │ ┌─────────────┐ │ │
│ │ │ Redis │ │ │
│ │ │ 8-alpine │ │ │
│ │ │ vol: data │ │ │
│ │ │ maxmem 2gb │ │ │
│ │ │ LRU evict │ │ │
│ │ └─────────────┘ │ │
│ │ │ │
│ └─────────────────────────────────────────────────────────┘ │
│ │
│ Source: compose.yml │
└───────────────────────────────────────────────────────────────┘
```

In production, the FastAPI backend does not expose any ports to the host. It is only accessible through the Nginx container on the internal Docker network. Databases use named volumes for persistence and `restart: always` for automatic recovery. The frontend container serves the pre-built SolidJS static files through Nginx.

The compose file (`compose.yml`) uses `depends_on` with `condition: service_healthy` to ensure databases are ready before the backend starts. Each database has a healthcheck command (PostgreSQL: `pg_isready`, SurrealDB: `/health`, Redis: `redis-cli ping`).

---

## Error Handling Strategy

### Custom Exception Hierarchy

Defined in `backend/app/core/exceptions.py`:

```
AppException (base)
 ├── UserExistsError → 409 Conflict
 ├── UserNotFoundError → 404 Not Found
 ├── UserInactiveError → 403 Forbidden
 ├── CredentialNotFoundError → 404 Not Found
 ├── CredentialVerificationError → 401 Unauthorized
 ├── ChallengeExpiredError → 400 Bad Request
 ├── DatabaseError → 500 Internal Server Error
 ├── AuthenticationError → 401 Unauthorized
 └── InvalidDataError → 400 Bad Request
```

`slowapi.errors.RateLimitExceeded` is also handled here and maps to 429 Too Many Requests.

### Exception Handlers

Registered in `backend/app/core/exception_handlers.py` via `register_exception_handlers(app)`, called from `factory.py`. Each exception type maps to a handler function that returns a `JSONResponse` with the appropriate HTTP status code.

For security-sensitive errors (`DatabaseError`), the response body contains a generic message ("Internal server error") rather than the actual error detail. The detail is logged server-side but not exposed to the client.

### WebSocket Error Format

WebSocket errors are sent as JSON to the client:

```json
{
 "type": "error",
 "error_code": "invalid_json",
 "error_message": "Invalid JSON format"
}
```

Error codes include: `max_connections`, `database_error`, `invalid_json`, `missing_type`, `unknown_type`, `processing_error`. These are defined inline in `websocket.py` and `websocket_manager.py` .

---

## Extensibility

Where to add new features:

| What | Where | Steps |
|---|---|---|
| New API endpoint | `api/` directory | 1. Create router in `api/new_feature.py` 2. Create service in `services/new_feature_service.py` 3. Register router in `factory.py` (after) |
| New database model | `models/` directory | 1. Create model class inheriting `BaseDBModel` 2. Import it somewhere that loads at startup (e.g., `models/__init__.py`) 3. `init_db` auto-creates the table via `SQLModel.metadata.create_all` |
| New encryption algorithm | `frontend/src/crypto/` | 1. Add implementation in `frontend/src/crypto/` 2. Add config constants in `config.py` 3. Wire into `message_service.py` or `crypto-service.ts` |
| New WebSocket message type | `websocket_service.py` | 1. Add constant in `config.py` (WS_MESSAGE_TYPE_*) 2. Add handler method in `WebSocketService` 3. Add routing case in `route_message` |
| New SurrealDB collection | `surreal_manager.py` | 1. Add CRUD methods in `SurrealDBManager` 2. Add response schema in `schemas/surreal.py` |

---

## Limitations

These are known architectural limitations, not bugs:

1. **No group chat encryption.** The Double Ratchet is a two-party protocol. Group chat encryption would require either Sender Keys (what Signal uses for groups, where each member maintains a separate ratchet with every other member) or the MLS (Messaging Layer Security) protocol. Neither is implemented.

2. **No post-quantum key exchange.** X25519 is vulnerable to Shor's algorithm on a sufficiently powerful quantum computer. Migrating to a hybrid scheme (X25519 + ML-KEM) would future-proof the key exchange, but this adds complexity and the quantum threat timeline is debated.

3. **Metadata not protected.** The server knows who sends messages to whom, when, how frequently, and the approximate size of each message. Only the content is encrypted. Metadata protection would require techniques like onion routing, padding, or dummy traffic, all of which add significant complexity and performance cost.

4. **No message deletion or expiry.** Once a message is stored in SurrealDB, it stays there indefinitely. There is no TTL on messages and no "delete for everyone" feature. SurrealDB does support the `_schedule_room_deletion` method for ephemeral rooms (`surreal_manager.py`), but this is room-level, not message-level.

5. **Single-region deployment.** The Docker Compose setup assumes all services run on one machine or one cluster. There is no geo-distribution, no CDN for the frontend, and no database replication. For a production deployment serving users across regions, you would need to add these.

6. **No offline message queue.** If a recipient is offline when a message is sent, the message is stored in SurrealDB but only delivered when the recipient connects and the live query fires. There is no explicit mechanism for fetching missed messages on reconnect beyond the live query catching up. The `get_room_messages` method (`surreal_manager.py`) exists for fetching message history, but the client must explicitly call it.

---

## Key Files Reference

| What | Where |
|---|---|
| App factory | `backend/app/factory.py` |
| Lifespan (DB init) | `backend/app/factory.py` (`lifespan`) |
| Settings + crypto constants | `backend/app/config.py` |
| Auth dependency | `backend/app/core/dependencies.py` (`current_user`) |
| Session helpers | `backend/app/core/dependencies.py` (`issue_session`, `revoke_session`) |
| WebAuthn manager | `backend/app/core/passkey/passkey_manager.py` |
| Clone detection | `passkey_manager.PasskeyManager.verify_authentication` |
| WebSocket pool | `backend/app/core/websocket_manager.py` |
| SurrealDB client | `backend/app/core/surreal_manager.py` |
| Redis client (sessions, challenges) | `backend/app/core/redis_manager.py` |
| Exception types | `backend/app/core/exceptions.py` |
| Exception handlers | `backend/app/core/exception_handlers.py` |
| Pass-through message storage | `backend/app/services/message_service.py` (`store_encrypted_message`) |
| Public prekey storage + bundle lookup | `backend/app/services/prekey_service.py` |
| Auth service | `backend/app/services/auth_service.py` |
| WS message router (membership-checked) | `backend/app/services/websocket_service.py` |
| Auth endpoints (incl. `/auth/me`, `/auth/logout`) | `backend/app/api/auth.py` |
| Encryption endpoints (bundle + upload) | `backend/app/api/encryption.py` |
| Rooms (membership-gated CRUD) | `backend/app/api/rooms.py` |
| WebSocket endpoint (cookie-authenticated) | `backend/app/api/websocket.py` |
| User model (with `webauthn_user_handle`) | `backend/app/models/User.py` |
| Credential model | `backend/app/models/Credential.py` |
| Identity public keys | `backend/app/models/IdentityKey.py` |
| Signed prekey publics | `backend/app/models/SignedPrekey.py` |
| One-time prekey publics | `backend/app/models/OneTimePrekey.py` |
| DB engine + sessions | `backend/app/models/Base.py` |
| Client crypto primitives | `frontend/src/crypto/primitives.ts` |
| Client crypto orchestration | `frontend/src/crypto/crypto-service.ts` |
| Client Double Ratchet | `frontend/src/crypto/double-ratchet.ts` |
| Client X3DH | `frontend/src/crypto/x3dh.ts` |
| Client IndexedDB key store | `frontend/src/crypto/key-store.ts` |
| Production compose | `compose.yml` |
| Development compose | `dev.compose.yml` |
