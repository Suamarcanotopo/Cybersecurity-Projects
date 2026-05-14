# Extension Challenges

These challenges extend the encrypted P2P chat with real features used in production messaging systems. They are ordered by difficulty and build on each other where noted.

Each challenge references actual files in this project. The line numbers point you to the exact code you need to understand before you start. Read those lines first.

---

## Easy Challenges

---

### Challenge 1: Read Receipts

**What to build:** When Bob reads a message from Alice, send an encrypted read receipt back to Alice so she sees "Read" status on her message.

**Why it matters:** Every modern messaging app has read receipts. Signal, WhatsApp, and iMessage all implement this. The interesting part is that read receipts themselves should be encrypted, because knowing WHEN someone read a message is metadata worth protecting. An adversary who can observe receipt timing can infer conversation patterns, responsiveness, and even sleep schedules.

**What you will learn:**
- WebSocket bidirectional messaging patterns
- Extending the existing message type routing
- UI state management for message delivery status

**Where to start reading:**

The backend already has the scaffolding for this. Look at these files:

- `backend/app/config.py` defines `WS_MESSAGE_TYPE_RECEIPT = "receipt"` already
- `backend/app/services/backend/app/services/websocket_service.py` already routes receipt messages to `handle_read_receipt`
- `backend/app/services/backend/app/services/websocket_service.py` has a working `handle_read_receipt` implementation
- `backend/app/schemas/websocket.py` defines `ReadReceiptWS` with `message_id`, `user_id`, and `read_at`

So the backend is done. The work is on the frontend.

**Implementation approach:**

1. When Bob's client decrypts and displays a message from Alice, emit a receipt through the WebSocket:
 ```json
 {
 "type": "receipt",
 "message_id": "messages:abc123",
 "sender_id": "alice-uuid-here"
 }
 ```

2. Alice's client receives the `ReadReceiptWS` via the WebSocket message handler at `frontend/src/websocket/message-handlers.ts`. Add a handler for the `"receipt"` message type.

3. Update the message store (`frontend/src/stores/messages.store.ts`) to track message status. Add a `status` field with values: `"sending"`, `"sent"`, `"delivered"`, `"read"`.

4. In the `MessageBubble.tsx` component (`frontend/src/components/Chat/MessageBubble.tsx`), render the status below the message text for outgoing messages.

**Design decisions you need to make:**
- Should receipts be encrypted? The current implementation sends them in plaintext over the WebSocket. A production system would encrypt them through the Double Ratchet, but that means each receipt advances the ratchet state. That is a meaningful tradeoff.
- Should you batch receipts? If Bob scrolls through 50 unread messages, sending 50 individual receipts is wasteful. Consider sending one receipt for the latest message ID (implying all prior messages are also read).
- What happens if Bob reads a message while offline (loaded from IndexedDB)? The receipt needs to be queued and sent when the WebSocket reconnects.

**How to test:**
- Open two browser tabs as different users
- Send a message from Tab A to Tab B
- Verify Tab A shows "Sent" initially
- Switch to Tab B and open the conversation, verify Tab A updates to "Read"
- Check the browser DevTools Network tab (WS frames) to confirm the receipt travels over WebSocket, not a separate HTTP request
- Close Tab B, send another message from Tab A, reopen Tab B, verify the receipt still works

---

### Challenge 2: Typing Indicators

**What to build:** Show "Alice is typing..." in Bob's chat window while Alice is composing a message.

**Why it matters:** Presence indicators are standard in messaging. The challenge is implementing them efficiently. A naive implementation floods the WebSocket with keypress events. A good implementation throttles to minimize bandwidth while keeping the UI responsive.

**What you will learn:**
- WebSocket event throttling and debouncing
- Ephemeral state management (state that never persists to any database)
- Frontend reactive updates with nanostores

**Where to start reading:**

This feature is substantially built already. Study what exists:

- `backend/app/config.py` defines `WS_MESSAGE_TYPE_TYPING = "typing"`
- `backend/app/services/backend/app/services/websocket_service.py` routes typing messages to `handle_typing_indicator`
- `backend/app/services/backend/app/services/websocket_service.py` broadcasts typing events to the room via `connection_manager.broadcast_to_room`
- `backend/app/schemas/websocket.py` defines `TypingIndicatorWS` with `user_id`, `room_id`, `is_typing`
- `frontend/src/stores/typing.store.ts` is a complete typing store with auto-clear timeouts (5 seconds,)
- `frontend/src/components/Chat/TypingIndicator.tsx` already renders the typing indicator UI

The backend and most of the frontend state management are done. What is missing:

**Implementation approach:**

1. In the `ChatInput.tsx` component (`frontend/src/components/Chat/ChatInput.tsx`), add an `onInput` handler that sends a typing event through the WebSocket.

2. Throttle the typing events. You do not want to send one per keystroke. Implement a 3-second throttle window: send one "is_typing: true" event, then suppress all further events for 3 seconds. When the user stops typing (no keystrokes for 3 seconds), send "is_typing: false".

3. In the WebSocket message handler (`frontend/src/websocket/message-handlers.ts`), handle incoming `"typing"` messages by calling `setUserTyping` from the typing store.

4. Wire the `TypingIndicator.tsx` component into the chat view if it is not already connected.

**Throttling pattern:**
```
Keystroke at t=0ms -> send "typing: true"
Keystroke at t=500ms -> suppress (within 3s window)
Keystroke at t=1.2s -> suppress
Keystroke at t=4.5s -> send "typing: true" (new window)
No input for 3s -> send "typing: false"
```

**Do not encrypt typing events.** They are ephemeral metadata. Running them through the Double Ratchet would advance the ratchet state for throwaway data, wasting chain keys and increasing the risk of desynchronization.

**How to test:**
- Open two tabs as different users in the same room
- Start typing in Tab A
- Verify "typing..." appears in Tab B within 1 second
- Stop typing and verify the indicator disappears after 5 seconds (the `TYPING_TIMEOUT_MS` constant at `typing.store.ts`)
- Type rapidly and verify only one WebSocket event per 3-second window (check WS frames in DevTools)
- Switch rooms and verify typing state resets

---

### Challenge 3: Message Timestamps and Ordering

**What to build:** Display human-readable timestamps on messages ("2:34 PM", "Yesterday", "Jan 15") and ensure messages display in correct chronological order even when they arrive out of order over the WebSocket.

**Why it matters:** The Double Ratchet protocol handles cryptographic out-of-order delivery (see `frontend/src/crypto/double-ratchet.ts` for the skipped message key logic), but the UI also needs to handle display ordering correctly. This is a common source of bugs in messaging apps. If Alice sends message A then message B, but B arrives at Bob first over the WebSocket, the UI must still display A before B.

**What you will learn:**
- Client-side message sorting with stable ordering
- Date formatting and localization using the `Intl` APIs
- Handling clock skew between devices

**Where to start reading:**

- `backend/app/schemas/websocket.py` shows `EncryptedMessageWS` includes a `timestamp` field
- `frontend/src/crypto/message-store.ts` already sorts messages by `created_at`
- `frontend/src/lib/date.ts` is the existing date utility file
- `frontend/src/components/Chat/MessageBubble.tsx` renders individual messages

**Implementation approach:**

1. The message store at `message-store.ts` already sorts by `created_at`. Verify this works when messages arrive out of order by checking that new messages insert at the correct position, not just appended at the end.

2. Create a timestamp formatter. Use `Intl.RelativeTimeFormat` for recent messages and `Intl.DateTimeFormat` for older ones:
 - Under 1 minute: "Just now"
 - Under 1 hour: "12 min ago"
 - Same day: "2:34 PM"
 - Yesterday: "Yesterday at 2:34 PM"
 - Same year: "Jan 15 at 2:34 PM"
 - Older: "Jan 15, 2025 at 2:34 PM"

3. Add date separator headers between messages from different days. When rendering the message list, compare each message's date with the previous message. If they differ, insert a "--- January 15, 2025 ---" separator.

4. Handle clock skew. If Alice's clock is 5 minutes ahead, her messages will have future timestamps. Clamp displayed times to never be "in the future" relative to the recipient's clock.

**How to test:**
- Send several messages quickly between two users and verify chronological order
- Use browser DevTools to throttle the network to "Slow 3G", send multiple messages, and verify that out-of-order arrivals still display in the correct order
- Send a message, wait 5 minutes, send another. Verify a date separator does NOT appear (same day). Wait until the next calendar day and send another. Verify the separator appears.

---

### Challenge 4: User Online Status

**What to build:** Show green/gray dots next to usernames in the conversation list and chat header, indicating online/offline status in real time.

**Why it matters:** The project already has a complete backend presence system and a frontend presence store. This challenge connects the two through the WebSocket layer.

**What you will learn:**
- SurrealDB presence records and their lifecycle
- Frontend reactive state from WebSocket events
- UI indicators with real-time updates

**Where to start reading:**

The backend infrastructure is already built:

- `backend/app/core/websocket_manager.py` calls `presence_service.set_user_online(user_id)` on WebSocket connect
- `backend/app/core/websocket_manager.py` calls `presence_service.set_user_offline(user_id)` on disconnect (only when the last connection for that user closes)
- `backend/app/services/presence_service.py` sets online status in SurrealDB
- `backend/app/services/presence_service.py` sets offline status
- `backend/app/services/backend/app/services/websocket_service.py` handles presence update messages

The frontend store is also ready:

- `frontend/src/stores/presence.store.ts` has `$presenceByUser` map, `setUserPresence`, `getUserStatus`, `isUserOnline`
- `frontend/src/components/Chat/OnlineStatus.tsx` already renders the status indicator

**Implementation approach:**

1. When a user connects via WebSocket, the backend already updates SurrealDB presence. What is missing is broadcasting that change to the user's contacts. In `websocket_manager.py`, after `presence_service.set_user_online(user_id)` succeeds , broadcast a presence update to all rooms that user belongs to.

2. Add a `PresenceUpdateWS` handler in the frontend WebSocket message handler. When a `"presence"` message arrives, call `setUserPresence` from the presence store.

3. In `ConversationList.tsx` (`frontend/src/components/Chat/ConversationList.tsx`) and `ChatHeader.tsx` (`frontend/src/components/Chat/ChatHeader.tsx`), read from `$presenceByUser` to display the correct online/offline indicator.

4. On initial WebSocket connection, request the current presence of all the user's contacts. This could be a new HTTP endpoint (`GET /users/presence?user_ids=...`) or a special WebSocket message that returns a bulk presence snapshot.

**How to test:**
- Open Tab A as User1, verify User1 shows as online in the conversation list
- Open Tab B as User2, verify both show as online
- Close Tab B, verify User2 shows as offline in Tab A within a few seconds
- Reopen Tab B, verify User2 shows as online again

---

## Intermediate Challenges

---

### Challenge 5: Message Search (Encrypted)

**What to build:** Let users search their own message history by keyword. Since messages are E2E encrypted, the server cannot search. All searching must happen client-side after decryption.

**Why it matters:** This is a real engineering problem that Signal, WhatsApp, and iMessage each solve differently. Server-side search is impossible with E2E encryption, which is the entire point of E2E encryption. Client-side search requires careful design to balance security, performance, and UX.

Signal allows searching decrypted messages on-device. WhatsApp backs up messages to Google Drive/iCloud (optionally encrypted) for searchability. iMessage uses a local Spotlight index. Each approach has different security properties.

**What you will learn:**
- Client-side full-text search in encrypted applications
- IndexedDB as a search-capable local database
- Security tradeoffs between searchability and forward secrecy

**Where to start reading:**

- `frontend/src/crypto/message-store.ts` is the existing IndexedDB message store with `decrypted_messages` object store
- `frontend/src/crypto/message-store.ts` creates indexes on `room_id`, `created_at`, and a compound `room_created` index
- `frontend/src/crypto/message-store.ts` shows how messages are queried by room
- `frontend/src/crypto/key-store.ts` shows `clearAllKeys` which wipes all crypto state on logout

**Implementation approach:**

1. Decrypted messages are already stored in IndexedDB at `message-store.ts` (`saveDecryptedMessage`). The plaintext is already persisted locally. You do not need to add a separate plaintext store.

2. Add a `searchMessages` function to `message-store.ts`. IndexedDB does not support full-text search natively. You have two options:

 Option A (simple): Load all messages for the user, filter with `String.prototype.includes` or a regex. This works for small message histories (under 10,000 messages).

 Option B (performant): Build a simple inverted index in a separate IndexedDB object store. On each message save, tokenize the plaintext, store `{token: string, message_id: string}` entries. Search queries look up tokens in the index. This scales to hundreds of thousands of messages.

3. Build a search UI. Add a search input to the sidebar. Results should show message previews with the matching text highlighted. Clicking a result should navigate to that message in the conversation and scroll it into view.

4. Clear the search index on logout. Add this to whatever logout function already calls `clearAllKeys` and `clearAllMessages`.

**Security considerations:**

The local plaintext store is a security tradeoff. If the device is compromised, the search history exposes message content. Signal handles this by only searching messages from the current app session (not backed by a persistent index). Consider offering a setting: "Enable message search (stores decrypted messages locally)" vs. "Maximum security (no local message storage)".

Also consider: IndexedDB data survives browser cache clears in some browsers. Use `indexedDB.deleteDatabase` on logout, not just clearing object stores.

**How to test:**
- Send several messages containing known keywords between two users
- Search for a keyword and verify matching messages appear in results
- Search for a keyword that appears in multiple rooms and verify results are grouped by room
- Log out and verify the search index is cleared (check IndexedDB in DevTools Application tab)
- Search with no results and verify an appropriate empty state renders

---

### Challenge 6: File Sharing (Encrypted)

**What to build:** Allow users to send encrypted files (images, documents, audio) through the chat. Files must be encrypted client-side with the same E2E encryption guarantees as text messages.

**Why it matters:** File sharing is a core feature of any messaging app. The challenge is encrypting large binary data efficiently while maintaining the same security properties as text messages. A 50MB video cannot be encrypted the same way as a 200-byte text message. You need chunked encryption, progress indicators, and a separate upload path.

**What you will learn:**
- Encrypting large binary data with AES-256-GCM
- Chunked encryption for memory efficiency
- File upload APIs with binary data handling
- Thumbnail generation for image previews
- MIME type handling and content-type security

**Where to start reading:**

- `frontend/src/crypto/frontend/src/crypto/primitives.ts` is the `aesGcmEncrypt` function. It accepts `Uint8Array` for plaintext, which means binary data works directly with no conversion needed.
- `frontend/src/crypto/frontend/src/crypto/primitives.ts` is `aesGcmDecrypt`
- `backend/app/services/backend/app/services/message_service.py` is `store_encrypted_message` which stores to SurrealDB
- `backend/app/config.py` defines `ENCRYPTED_CONTENT_MAX_LENGTH = 50000` (this limits inline message content, not file uploads)

**Implementation approach:**

1. **Client: Read and encrypt the file**
 - Use `FileReader.readAsArrayBuffer` to get the raw bytes
 - For small files (under 1MB): encrypt the entire file as one AES-256-GCM operation using a message key from the Double Ratchet
 - For large files (over 1MB): chunk into 1MB segments. Encrypt each chunk with a derived key: `chunk_key = HKDF(message_key, salt=chunk_index)`
 - Each chunk gets its own nonce (never reuse nonces)

2. **Client: Upload encrypted blob**
 - Create a new backend endpoint: `POST /api/messages/file`
 - Send the encrypted blob as multipart form data
 - Include metadata in the request: original filename, MIME type, file size, number of chunks, encryption header (same format as text message headers)

3. **Backend: Store encrypted file**
 - Store the encrypted blob on disk or in object storage (not in SurrealDB, which is not designed for large binary data)
 - Store file metadata in SurrealDB: `file_id`, `sender_id`, `recipient_id`, `room_id`, `filename`, `mime_type`, `size`, `chunk_count`, `storage_path`
 - Return a `file_id` to the client

4. **Client: Send file message**
 - Send a regular encrypted message through the WebSocket, but the plaintext content is JSON metadata:
 ```json
 {
 "type": "file",
 "file_id": "abc123",
 "filename": "document.pdf",
 "mime_type": "application/pdf",
 "size": 1048576,
 "thumbnail": "<base64-encoded-encrypted-thumbnail>"
 }
 ```
 - The recipient decrypts this metadata, then downloads the encrypted file by `file_id`, then decrypts the file client-side

5. **For images: generate encrypted thumbnails**
 - Before uploading, use `<canvas>` to resize the image to a thumbnail (200x200)
 - Encrypt the thumbnail separately
 - Include the encrypted thumbnail inline in the message (it is small enough)
 - Render the thumbnail immediately, load the full image on click

**Security considerations:**
- Validate file size limits on the backend to prevent DoS (suggest 100MB max)
- The server validates file size and MIME type headers, but cannot verify encrypted content matches the claimed MIME type. The client must validate after decryption.
- Consider using separate encryption keys for files vs. text messages. If a file key is compromised, it should not compromise the text message ratchet.
- Strip EXIF data from images before encryption (EXIF contains GPS coordinates, camera model, timestamps)

**Chunked encryption detail:**

For files over 1MB, you need a chunking strategy. Here is a concrete approach:

1. Split the file into 1MB (1,048,576 byte) chunks
2. For each chunk, derive a per-chunk key: `chunk_key_i = HKDF(message_key, salt=uint32_to_bytes(i), info=b'file_chunk')`
3. Encrypt each chunk: `encrypted_chunk_i = AES-GCM(chunk_key_i, chunk_i, associated_data=file_id || chunk_index || total_chunks)`
4. The associated data binding prevents an attacker from reordering, duplicating, or truncating chunks
5. Upload chunks sequentially or in parallel (the server stores them as `{file_id}_chunk_{i}`)

On the receiving end:
1. Download all chunks
2. Derive the same per-chunk keys from the message key
3. Decrypt each chunk, verify the associated data
4. Concatenate decrypted chunks to reconstruct the original file

**Progress tracking:**

For large files, display upload/download progress:
- Track bytes uploaded/downloaded vs. total file size
- Show a progress bar in the `MessageBubble` component
- Allow cancellation mid-transfer (clean up partial uploads on the server)

**How to test:**
- Send a small text file (.txt, under 1KB) between two users, verify the recipient can download and decrypt it
- Send an image (.png, under 5MB), verify a thumbnail appears immediately and the full image loads on click
- Send a large file (over 10MB), verify chunked encryption works and a progress bar appears
- Verify the server filesystem contains only encrypted blobs (open a stored file in a hex editor, confirm it looks like random data)
- Send a file to an offline user, verify they can download and decrypt it when they come online
- Cancel a large file upload mid-transfer, verify partial data is cleaned up
- Send a file with a tampered chunk (flip one byte), verify decryption fails with an authentication error

---

### Challenge 7: Multi-Device Sync

**What to build:** Allow a user to be logged in on multiple devices simultaneously, with messages synced across all devices while maintaining E2E encryption.

**Why it matters:** This is one of the hardest problems in E2E encrypted messaging. Signal uses the "linked devices" approach where each device has its own identity key and its own ratchet session with every contact. WhatsApp uses a multi-device architecture where the phone is the primary device and other devices get proxy sessions. iMessage gives each device its own key pair and encrypts each message N times (once per recipient device).

Each approach has different properties for security, UX, and complexity. This challenge uses Signal's approach because it is the most secure and the codebase already supports multiple WebSocket connections per user.

**What you will learn:**
- Multi-device identity key management
- Session multiplication (N devices means N separate ratchet sessions per contact)
- Device linking and verification
- Conflict resolution in distributed cryptographic state

**Where to start reading:**

- `backend/app/core/websocket_manager.py` stores `active_connections: dict[UUID, list[WebSocket]]` which already supports multiple connections per user
- `backend/app/core/websocket_manager.py` enforces `WS_MAX_CONNECTIONS_PER_USER` (default 5, see `config.py`)
- `backend/app/core/websocket_manager.py` iterates over ALL connections for a user when sending a message
- `backend/app/services/backend/app/services/prekey_service.py` initializes user keys with identity key, signed prekey, and one-time prekeys
- `backend/app/models/IdentityKey.py` stores one identity key per user (this needs to change)
- `backend/app/services/backend/app/services/message_service.py` `initialize_conversation` creates one ratchet per user pair (this also needs to change)

**Architecture change:**

Currently, the relationship is:
```
Alice ----[one ratchet session]----> Bob
```

With multi-device, it becomes:
```
Alice-Phone ----[ratchet A1-B1]----> Bob-Phone
Alice-Phone ----[ratchet A1-B2]----> Bob-Laptop
Alice-Laptop ----[ratchet A2-B1]----> Bob-Phone
Alice-Laptop ----[ratchet A2-B2]----> Bob-Laptop
```

If Alice has 2 devices and Bob has 3 devices, there are 2 x 3 = 6 ratchet sessions between them. When Alice sends a message to Bob, she encrypts it 3 times (once per Bob device). Each of Bob's devices decrypts independently.

**Implementation phases:**

**Phase 1: Database schema changes**
- Add a `device_id` column to the `IdentityKey`, `SignedPrekey`, and `OneTimePrekey` models. Change the unique constraint on `IdentityKey` from `(user_id)` to `(user_id, device_id)`.
- Add a `devices` table: `device_id`, `user_id`, `device_name`, `created_at`, `last_active`.
- Client-side ratchet state in `frontend/src/crypto/key-store.ts` becomes keyed on `(peer_user_id, peer_device_id)` instead of just `peer_id`.

**Phase 2: Device registration**
- When a user registers a new device (via WebAuthn), generate a new identity key pair for that device.
- Each device uploads its own prekey bundle (identity key, signed prekey, one-time prekeys).
- The prekey bundle endpoint (`backend/app/services/prekey_service.py`) needs a `device_id` parameter.

**Phase 3: Message fan-out**
- Alice's client fetches all of Bob's per-device prekey bundles, then runs X3DH and encrypts once per device.
- The WebSocket payload from Alice to the server now carries `device_id` alongside `recipient_id`.
- The forwarding logic in `backend/app/services/websocket_service.py:handle_encrypted_message` routes each ciphertext to the recipient device's connection.

**Phase 4: Device linking**
- A new device should NOT just register independently. It should be "linked" by an existing device.
- Linking flow: new device displays a QR code containing its temporary public key. Existing device scans the QR code, performs a key exchange with the new device, and uploads a "device link" record to the server.
- Without linking, the server could register a rogue device and intercept messages.

**Message delivery to multiple devices:**

When Alice sends a message to Bob (who has 3 devices), the flow is:

1. Alice's client fetches prekey bundles for ALL of Bob's devices: `GET /encryption/prekey-bundle/{bob_id}?all_devices=true`
2. Alice performs X3DH separately with each device's prekey bundle (3 separate key exchanges)
3. Alice encrypts the message 3 times (once per ratchet session)
4. Alice sends 3 encrypted payloads to the server, each tagged with `(recipient_id, device_id)`
5. The server forwards each payload to the correct device

This means the `store_encrypted_message` function at `backend/app/services/message_service.py` needs a `device_id` field. The SurrealDB message schema changes from `{sender_id, recipient_id, ciphertext}` to `{sender_id, sender_device_id, recipient_id, recipient_device_id, ciphertext}`.

**Device verification:**

How does Alice know she is encrypting to Bob's real devices and not a rogue device injected by the server? This is the same trust problem as the single-device case, but magnified. Each device has its own "safety number" (a hash of the identity key pair). Users should verify safety numbers for each device, not just each contact.

Consider implementing a device list that shows all registered devices with their safety numbers:
```
Bob's Devices:
 Phone (registered Jan 15) - Safety: 4a7b 2c3d ...
 Laptop (registered Jan 20) - Safety: 9f1e 8d2c ...
 Tablet (registered Feb 1) - Safety: 3b5a 7c4e ...
```

**How to test:**
- Register two devices for the same user (two different browser profiles or one regular + one incognito)
- Send a message from a third user to the multi-device user
- Verify BOTH devices receive and can decrypt the message independently
- Verify each device has independent ratchet state (advancing the ratchet on device A does not affect device B)
- Disconnect one device, send messages, reconnect, and verify the reconnected device catches up
- Register a third device and verify it establishes new ratchet sessions with all existing contacts
- Remove a device and verify it can no longer decrypt new messages

---

## Advanced Challenges

---

### Challenge 8: Group Encryption with Sender Keys

**What to build:** Implement group chat encryption using the Sender Keys protocol (used by Signal for group messaging). In a group chat, each member has a "sender key" that they distribute to all other members. When sending a group message, you encrypt once with your sender key, and all members can decrypt.

**Why it matters:** In 1:1 encryption, you encrypt each message once. In a group of N members, the naive approach encrypts each message N-1 times (once per other member). Sender Keys reduce this to O(1) encryption per message, which matters at scale. A group of 1000 members would require 999 encryptions per message without Sender Keys.

Signal uses Sender Keys for group chats. WhatsApp adopted the same approach. The tradeoff is weaker forward secrecy compared to the Double Ratchet, because the sender key chain only ratchets forward (no DH ratchet).

**What you will learn:**
- Sender Keys protocol design and implementation
- Group key distribution and rotation
- Member addition/removal key management
- The security tradeoffs between O(1) group encryption and O(N) pairwise encryption

**Why this is hard:**
- Adding a new member requires distributing ALL existing sender keys to them (via 1:1 encrypted channels)
- Removing a member requires rotating ALL sender keys (the removed member knows the old keys and could derive all future chain keys from them)
- Members who miss a key rotation cannot decrypt new messages until they receive the new sender key
- Forward secrecy is weaker than 1:1. Compromising a sender key exposes ALL future messages from that sender until the next rotation.

**Where to start reading:**

- `backend/app/api/rooms.py` creates rooms with participants. This is where group support starts.
- `frontend/src/crypto/double-ratchet.ts` has the chain key derivation (`_kdf_ck`) which is the same pattern used in Sender Keys (single-direction chain)
- `backend/app/core/websocket_manager.py` `broadcast_to_room` sends to all room members
- `frontend/src/crypto/frontend/src/crypto/primitives.ts` AES-GCM encryption works for sender key messages too

**Implementation phases:**

**Phase 1: Research**

Read Signal's Sender Keys specification. Understand the difference between "sender key distribution messages" (sent via 1:1 ratchets) and regular group messages (encrypted with the sender key).

A sender key is a pair: `(chain_key, signing_key)`. The chain key advances like a single-direction ratchet (HMAC-based). The signing key authenticates the sender.

**Phase 2: Database schema**

Create these tables in SurrealDB:

```
sender_keys {
 group_id: string,
 user_id: string,
 chain_key: bytes,
 chain_iteration: int,
 signing_public_key: bytes,
 created_at: datetime
}

group_members {
 group_id: string,
 user_id: string,
 role: string, // "admin" | "member"
 joined_at: datetime
}
```

**Phase 3: Implementation**

1. **Group creation:** When Alice creates a group with Bob and Carol:
 - Alice generates a sender key pair: `(chain_key_alice, signing_key_alice)`
 - Alice sends her sender key to Bob via their existing 1:1 encrypted channel (Double Ratchet)
 - Alice sends her sender key to Carol the same way
 - Bob and Carol do the same (each distributes their sender key to all other members)
 - Result: each member has N-1 sender keys (one per other member)

2. **Sending a message:** Alice encrypts the group message:
 - Derive message key: `message_key = HMAC-SHA256(chain_key, 0x01)`
 - Advance chain: `chain_key = HMAC-SHA256(chain_key, 0x02)`
 - Encrypt: `ciphertext = AES-GCM(message_key, plaintext)`
 - Sign: `signature = Ed25519.sign(signing_key, ciphertext)`
 - Broadcast ciphertext + signature + chain_iteration to the group

3. **Receiving a message:** Bob decrypts:
 - Look up Alice's sender key by `(group_id, sender_id)`
 - If `chain_iteration > local_iteration`: advance chain key to catch up
 - Derive the message key, decrypt, verify signature

4. **Member removal:** When Carol is removed:
 - Alice generates a NEW sender key pair
 - Alice distributes the new sender key to Bob (but NOT Carol)
 - Bob does the same
 - Carol still has the old sender keys but they are no longer used

5. **Member addition:** When Dave joins:
 - All existing members distribute their current sender keys to Dave via 1:1 channels
 - Dave generates and distributes his sender key to all members

**Key rotation strategy:**

Sender keys should rotate periodically, not just on member removal. Consider rotating after every 100 messages or every 24 hours, whichever comes first. This limits the blast radius of a compromised sender key: an attacker who obtains Alice's sender key can only decrypt messages from Alice's current chain, not past chains.

When a sender key rotates:
1. The sender generates a new sender key pair
2. The sender distributes the new key to all group members via 1:1 encrypted channels
3. The sender includes a "key rotation" flag in the first message with the new key
4. Recipients who receive a message with an unknown sender key chain must request a key distribution message

**Error handling for missed key distributions:**

If Bob misses a key distribution (he was offline when Alice rotated her sender key), he cannot decrypt Alice's new messages. Handle this gracefully:
1. Bob receives a message from Alice with an unknown chain iteration
2. Bob's client sends a "request sender key" message to Alice via 1:1 channel
3. Alice re-distributes her current sender key to Bob
4. Bob can now decrypt the buffered messages

This recovery mechanism is critical. Without it, a single missed key distribution permanently breaks the group for that member.

**How to test:**
- Create a group with 3 users
- Send a message from each user, verify all members can decrypt
- Remove one member, send a new message, verify the removed member cannot decrypt
- Add a new member, verify they can decrypt new messages
- Verify they cannot decrypt messages sent before they joined (unless you explicitly implement history sharing)
- Take one member offline, rotate a sender key, bring them back online, verify they can recover via the key re-request mechanism
- Send 101 messages from one user and verify automatic key rotation triggers

---

### Challenge 9: Post-Quantum Key Exchange (Hybrid X25519 + Kyber)

**What to build:** Add a hybrid key exchange that combines classical X25519 with CRYSTALS-Kyber (ML-KEM), making the initial key agreement resistant to quantum computer attacks while maintaining security against classical computers.

**Why it matters:** Quantum computers running Shor's algorithm can break all current public-key cryptography based on the discrete logarithm problem, including X25519 and Ed25519. This is not hypothetical timeline speculation. Signal added post-quantum protection (PQXDH) in September 2023. Google Chrome uses hybrid ML-KEM for TLS since 2024. NIST finalized the ML-KEM standard (FIPS 203) in August 2024.

The threat model that motivates this is "harvest now, decrypt later." An adversary records encrypted traffic today, stores it, and decrypts it in 10 years when they have a quantum computer. Hybrid PQ protection prevents this.

**What you will learn:**
- Post-quantum cryptography fundamentals (lattice-based key encapsulation)
- Hybrid key exchange design (classical + PQ combined)
- CRYSTALS-Kyber / ML-KEM key encapsulation mechanism
- Updating a production cryptographic protocol without breaking backwards compatibility

**Where to start reading:**

- `frontend/src/crypto/x3dh.ts` is `perform_x3dh_sender`. This is the exact function you will modify.
- `frontend/src/crypto/x3dh.ts` is where the DH shared secrets are combined:
 ```python
 dh1 = alice_ik_private.exchange(bob_spk_public)
 dh2 = alice_ek_private.exchange(bob_ik_public)
 dh3 = alice_ek_private.exchange(bob_spk_public)
 # dh4 = alice_ek_private.exchange(bob_opk_public) (optional)
 key_material = dh1 + dh2 + dh3 [+ dh4]
 ```
- `frontend/src/crypto/x3dh.ts` is where HKDF derives the shared key:
 ```python
 f = b'\xff' * X25519_KEY_SIZE
 hkdf = HKDF(algorithm=hashes.SHA256, length=X25519_KEY_SIZE,
 salt=b'\x00' * X25519_KEY_SIZE, info=b'X3DH')
 shared_key = hkdf.derive(f + key_material)
 ```
- `backend/pyproject.toml:30` already includes `liboqs-python>=0.14.1` in dependencies

**The hybrid approach:**

The key insight is that you combine BOTH classical and post-quantum shared secrets. If either one is secure, the combined result is secure. This means:
- If Kyber is broken but X25519 is not, you are still safe (classical security)
- If X25519 is broken (quantum computer) but Kyber is not, you are still safe (PQ security)
- Both must be broken simultaneously to compromise the session

```
Classical: SK_classical = HKDF(DH1 || DH2 || DH3 [|| DH4])
Post-quantum: SK_pq = Kyber.Decapsulate(ciphertext, secret_key)
Combined: SK = HKDF(SK_classical || SK_pq, info=b'PQXDH')
```

**Implementation phases:**

**Phase 1: Research**

Read these specifications:
- Signal's PQXDH specification: https://signal.org/docs/specifications/pqxdh/
- NIST FIPS 203 (ML-KEM): https://csrc.nist.gov/pubs/fips/203/final

Understand the difference between a KEM (Key Encapsulation Mechanism) and a DH exchange. In Kyber:
- Bob generates a Kyber keypair and publishes the public key
- Alice calls `Encapsulate(bob_public_key)` which returns `(shared_secret, ciphertext)`
- Alice sends `ciphertext` to Bob
- Bob calls `Decapsulate(ciphertext, bob_private_key)` which returns `shared_secret`
- Both sides now have the same `shared_secret`

**Phase 2: Prekey bundle extension**

1. Add a `kyber_public_key` field to the `PreKeyBundle` dataclass at `frontend/src/crypto/x3dh.ts`
2. When generating prekeys (`backend/app/services/prekey_service.py`), also generate a Kyber keypair using `liboqs-python`:
 ```python
 import oqs
 kem = oqs.KeyEncapsulation("Kyber768")
 kyber_public = kem.generate_keypair
 kyber_private = kem.export_secret_key
 ```
3. Store the Kyber public key in the prekey bundle, private key in the database

**Phase 3: X3DH extension**

Modify `perform_x3dh_sender` at `frontend/src/crypto/x3dh.ts`:

1. After computing the classical `key_material` , check if the bundle includes a Kyber key
2. If yes: encapsulate against the Kyber public key to get `(pq_shared_secret, pq_ciphertext)`
3. Concatenate: `combined_material = key_material + pq_shared_secret`
4. Change the HKDF info parameter: `info=b'PQXDH'` (to distinguish from classical sessions)
5. Include `pq_ciphertext` in the `X3DHResult` so it can be sent to the recipient

Modify `perform_x3dh_receiver` at `frontend/src/crypto/x3dh.ts`:

1. After computing the classical key material, check if a PQ ciphertext was provided
2. If yes: decapsulate to recover `pq_shared_secret`
3. Combine and derive as above

**Phase 4: Backwards compatibility**

If the peer does not have a Kyber public key in their prekey bundle (they have not upgraded), fall back to classical-only X3DH. The code path at `frontend/src/crypto/x3dh.ts` already handles the optional one-time prekey with an if/else. Use the same pattern for Kyber.

**Key sizes to be aware of:**
- X25519 public key: 32 bytes
- Kyber-768 public key: 1184 bytes
- Kyber-768 ciphertext: 1088 bytes
- Kyber-768 shared secret: 32 bytes

The prekey bundle size increases significantly. Plan for this in your database schema and WebSocket message size limits.

**How to test:**
- Two PQ-capable clients establish a session. Verify the shared key differs from a classical-only session with the same key material.
- A PQ-capable client talks to a classical-only client. Verify it falls back gracefully.
- Generate 1000 PQ sessions and verify all shared keys are unique.
- Benchmark: measure the time for X3DH with and without Kyber. Kyber should add under 10ms.

---

### Challenge 10: Disappearing Messages with Cryptographic Enforcement

**What to build:** Messages that automatically delete after a configurable time period, with the deletion enforced cryptographically. The decryption key is destroyed after the timer expires, making the message permanently unreadable even if the ciphertext persists.

**Why it matters:** Signal's disappearing messages feature is one of its most popular. But naive implementations just delete the UI element while the data remains in storage. If a forensic examiner recovers the database, the "deleted" messages are still there in plaintext or with intact keys.

This challenge implements true cryptographic deletion: the ciphertext remains in SurrealDB (you cannot guarantee physical deletion from a database), but the key needed to decrypt it is securely destroyed. Without the key, the ciphertext is indistinguishable from random noise.

**What you will learn:**
- Cryptographic deletion (destroying keys instead of data)
- Timer-based key lifecycle management
- Secure memory wiping (harder than it sounds in JavaScript and Python)
- Distributed timer synchronization between sender and recipient

**Where to start reading:**

- `frontend/src/crypto/double-ratchet.ts` is `_kdf_ck` which derives message keys. Each message gets a unique key.
- `frontend/src/crypto/double-ratchet.ts` is `_store_skipped_message_keys` with eviction logic -234. This is the pattern you will extend for TTL-based eviction.
- `frontend/src/crypto/double-ratchet.ts` is `_evict_oldest_skipped_keys` which deletes keys.
- `frontend/src/crypto/key-store.ts` stores ratchet state in IndexedDB
- `frontend/src/crypto/frontend/src/crypto/primitives.ts` has `generateRandomBytes` using `crypto.getRandomValues`

**Implementation approach:**

1. **Conversation setting:** Add a per-conversation setting: `disappear_after_seconds`. Values: 0 (disabled), 30, 300, 3600, 86400, 604800. Store this in the room metadata in SurrealDB.

2. **Message key storage with TTL:** When a message is encrypted, the message key is normally discarded after encryption. For disappearing messages, the RECIPIENT stores the message key in IndexedDB with a TTL:
 ```
 {
 message_id: "msg_abc123",
 message_key: <32 bytes>,
 created_at: "2025-01-15T14:30:00Z",
 expires_at: "2025-01-15T15:30:00Z" // created_at + disappear_after_seconds
 }
 ```

3. **Timer starts on read, not on send.** The recipient's timer starts when they first decrypt the message. If the recipient is offline for a week, they still get the full timer duration after reading.

4. **Key destruction:** When the timer expires:
 - Frontend: overwrite the key material with random bytes before deleting from IndexedDB. In JavaScript: `crypto.getRandomValues(keyBuffer)` then delete.
 - Backend: just delete the SurrealDB row. The server holds no keys, so there's nothing to wipe — but the recipient's locally-cached plaintext (and message key, if it's still in the skipped-key cache) needs to be overwritten on the client.

5. **UI changes:**
 - Show a countdown timer on disappearing messages
 - After expiration, replace the message content with "[Message expired]"
 - The ciphertext remains in SurrealDB but is now permanently unreadable

**The hard parts:**

- What happens if the recipient never reads the message? The sender's copy should still eventually disappear. Implement a "maximum lifetime" that triggers regardless of read status.
- What about screenshots? You cannot prevent them. This is a social problem, not a technical one. Signal shows a notification when a screenshot is taken (on mobile), but this is best-effort.
- JavaScript garbage collection does not guarantee memory is wiped. When you overwrite a `Uint8Array`, the old values may still exist in memory until the GC reclaims the page. True secure deletion in JavaScript is not possible. Document this limitation.
- The skipped message key cache (`frontend/src/crypto/double-ratchet.ts`) stores keys for out-of-order messages. These must also respect the TTL.

**How to test:**
- Enable disappearing messages (30 second timer) in a conversation
- Send a message, verify it appears normally
- Wait 30 seconds, verify the message content disappears and shows "[Message expired]"
- Check IndexedDB to verify the message key is gone
- Verify the ciphertext still exists in SurrealDB but cannot be decrypted (write a test script that attempts decryption and confirms it fails)

---

## Expert Challenges

---

### Challenge 11: Deniable Authentication (Triple DH)

**Estimated time:** 2-3 weeks

**What to build:** Implement deniable authentication so that neither Alice nor Bob can prove to a third party that the other sent a specific message. This is a privacy property of the Signal Protocol that most implementations skip or get wrong.

**Prerequisites:** Solid understanding of the X3DH implementation at `frontend/src/crypto/x3dh.ts`

**Why it matters:** In the current implementation, if Alice has Bob's signed messages (ciphertext + authentication tags), she could potentially show them to a third party to prove Bob said something. This is because the associated data (`frontend/src/crypto/x3dh.ts`) binds both identity keys to the session: `associated_data = alice_ik_public_bytes + bob_ik_public_bytes`.

Deniable authentication means that Alice could have forged the messages herself (because she also has the shared secret), so they are not valid cryptographic proof of Bob's authorship. This matters for journalists, activists, whistleblowers, and anyone who might be legally compelled to prove message authorship.

**The core problem:**

X3DH provides implicit authentication through the DH operations involving identity keys. Both DH1 (`IK_A x SPK_B`) and DH2 (`EK_A x IK_B`) involve at least one identity key. A third party who trusts Alice and knows both identity keys could verify that the session was established between those specific identities.

In a deniable protocol, the authentication MAC can be computed by EITHER party, so neither can prove the other computed it.

**Where to start reading:**

- `frontend/src/crypto/x3dh.ts` is the associated data computation: `associated_data = alice_ik_public_bytes + bob_ik_public_bytes`
- `frontend/src/crypto/double-ratchet.ts` is `encrypt_message` where associated data is used in AES-GCM
- `frontend/src/crypto/double-ratchet.ts` is `decrypt_message` which verifies the authentication tag

**Implementation approach:**

1. Replace the associated data binding with a commitment scheme. Instead of `AD = IK_A || IK_B`, use `AD = HMAC(shared_key, IK_A || IK_B)`. Both parties can compute this MAC (they both have the shared key), so neither can prove the other did.

2. Alternatively, implement a "triple DH" variant where you add a third DH: `DH5 = IK_A x IK_B`. This creates a shared secret that only requires Alice and Bob's identity keys. Since both parties can compute it, a transcript of messages authenticated with this secret is not proof against either party.

3. The associated data modification at `frontend/src/crypto/x3dh.ts` and the corresponding line at `frontend/src/crypto/x3dh.ts` must change in tandem (sender and receiver must produce the same associated data).

**How to verify deniability:**

Write a program that:
1. Takes a message transcript (ciphertexts + authentication tags)
2. Takes ONLY Alice's key material (not Bob's private keys)
3. Attempts to forge a valid transcript that looks identical
4. If it succeeds, the protocol is deniable (Alice could have created the transcript alone)

---

### Challenge 12: Secure Backup and Recovery

**Estimated time:** 3-4 weeks

**What to build:** Allow users to create encrypted backups of their message history and encryption keys, stored server-side but encrypted with a user-controlled backup key. This enables account recovery on a new device without losing message history.

**Prerequisites:** Complete Challenge 7 (Multi-Device Sync). You need to understand device key management before adding key backup.

**Why it matters:** The biggest UX problem with E2E encryption is that losing your device means losing your message history forever. This is mathematically inevitable if key material only exists on one device.

WhatsApp solved this with Google Drive/iCloud backups encrypted with a user password (using Argon2id). Signal solved it with PIN-based Secure Value Recovery (SVR), which uses SGX enclaves to rate-limit PIN guessing. Both approaches have tradeoffs.

**Planning questions you must answer before writing code:**

1. What key material needs to be backed up?
 - Identity keys (X25519 + Ed25519 private keys)
 - Active ratchet states for each conversation
 - Signed prekey private keys
 - Message history (optional, large)

2. How is the backup encrypted?
 - Option A: User PIN/password -> Argon2id -> AES-256-GCM key
 - Option B: Random backup key displayed as a 24-word recovery phrase
 - Option C: Server-side HSM with rate limiting (Signal's SVR approach, requires hardware)

3. Where is the backup stored?
 - Server-side (encrypted blob in PostgreSQL or object storage)
 - User-exported file (like Signal's plaintext export, but encrypted)

4. How do you handle backup key loss?
 - Unrecoverable by design (most secure)
 - Social recovery (N-of-M trusted contacts must approve, like Shamir's Secret Sharing)
 - Server-side recovery with identity verification (weakest, requires trusting the server)

**Where to start reading:**

- `frontend/src/crypto/key-store.ts` saves identity keys to IndexedDB. This is the data that needs backing up.
- `frontend/src/crypto/key-store.ts` saves ratchet states
- `frontend/src/crypto/key-store.ts` `clearAllKeys` deletes everything on logout
- `frontend/src/crypto/message-store.ts` saves decrypted messages

**Implementation phases:**

**Phase 1: Backup format design**

Define a JSON schema for the backup:
```json
{
 "version": 1,
 "created_at": "2025-01-15T14:30:00Z",
 "identity_keys": {
 "x25519_private": "<base64>",
 "x25519_public": "<base64>",
 "ed25519_private": "<base64>",
 "ed25519_public": "<base64>"
 },
 "ratchet_states": [
 {
 "peer_id": "bob-uuid",
 "root_key": "<base64>",
 "sending_chain_key": "<base64>",
 "receiving_chain_key": "<base64>",
 "dh_private_key": "<base64>",
 "dh_peer_public_key": "<base64>",
 "sending_message_number": 42,
 "receiving_message_number": 37,
 "previous_sending_chain_length": 12
 }
 ],
 "messages": []
}
```

**Phase 2: Backup encryption**

1. User enters a PIN or passphrase
2. Derive key: `backup_key = Argon2id(passphrase, salt, time_cost=3, memory_cost=65536, parallelism=4)`
3. Encrypt: `encrypted_backup = AES-256-GCM(backup_key, JSON.stringify(backup_data))`
4. Store `{salt, encrypted_backup, nonce}` on the server

**Phase 3: Backup upload/download endpoints**

- `POST /api/backup` - upload encrypted backup blob
- `GET /api/backup` - download encrypted backup blob
- `DELETE /api/backup` - delete backup

The server NEVER has the backup key. It stores only encrypted bytes.

**Phase 4: Restore flow**

1. User logs in on new device with WebAuthn
2. Server returns the encrypted backup blob
3. User enters PIN/passphrase
4. Client derives backup key, decrypts backup
5. Client writes identity keys and ratchet states to IndexedDB
6. Client resumes existing conversations using the restored ratchet states

**Phase 5: Edge case handling**

What happens when the restored device and the original device are both active? Their ratchet states diverge immediately (the first message from either device advances the ratchet differently on each). This is the same problem as Challenge 7 (Multi-Device). The solution is: on restore, the new device uses the backup as a starting point but establishes NEW ratchet sessions with all contacts (essentially re-keying every conversation).

**Success criteria:**
- User can create encrypted backup from the UI
- Backup can be restored on a new device (different browser profile)
- Restored device can send and receive messages in existing conversations
- Backup blob is useless without the passphrase (verify by attempting decryption with wrong passphrase)
- Server admin cannot read backup contents (verify by checking database contents)

---

## Mix and Match Projects

These combine multiple challenges into a single coherent application.

### Secure Team Messenger

**Combine:** Group Encryption (8) + File Sharing (6) + Read Receipts (1) + Multi-Device (7)

Build a team messaging app similar to Signal's group chat with file attachments and delivery status across multiple devices. This covers the feature set of a basic Slack competitor with E2E encryption.

### Whistleblower Platform

**Combine:** Disappearing Messages (10) + Deniable Authentication (11) + File Sharing (6)

Build a platform where sources can securely share documents with journalists. Messages self-destruct after reading, cannot be attributed to either party, and files are encrypted in transit and at rest. Think SecureDrop but with real-time chat.

### Enterprise Secure Chat

**Combine:** All Easy Challenges + Group Encryption (8) + Backup/Recovery (12) + Multi-Device (7)

Build a corporate messaging system with compliance features (backup and recovery for legal holds) while maintaining E2E encryption for message content. The tension between compliance (the company needs to audit messages) and privacy (E2E encryption prevents this) is a real product design challenge. Research how Wickr Enterprise and Element (Matrix) handle this.

---

## Performance Challenges

---

### Optimize Ratchet State Storage

The current implementation serializes the entire ratchet state to PostgreSQL on every single message. Look at `backend/app/services/message_service.py` (`_save_ratchet_state_to_db`). Every call to `send_encrypted_message` or `decrypt_received_message` triggers a full ratchet state write with `await session.commit` .

This is a bottleneck. For a conversation with rapid back-and-forth messaging, you are writing to PostgreSQL twice per message (once for encrypt, once for decrypt).

**Your task:** Profile the serialization overhead and implement a caching layer using Redis.

**Approach:**
1. On first ratchet state load, cache it in Redis with a key like `ratchet:{user_id}:{peer_user_id}`
2. After each ratchet advance, write to Redis only (sub-millisecond)
3. Periodically (every 10 messages or every 30 seconds) flush to PostgreSQL (durable storage)
4. On WebSocket disconnect (`websocket_manager.py`), flush all cached states to PostgreSQL
5. On startup, load from PostgreSQL (Redis is not durable across restarts)

**Measurement:** Benchmark messages per second before and after with a simple load test. Target: greater than 100 messages per second per conversation.

**Risk:** If the server crashes between Redis write and PostgreSQL flush, you lose ratchet state. This means the next message will fail to decrypt (ratchet desynchronization). Mitigate with a background flush task and short flush intervals.

**Detailed profiling steps:**

1. Add timing instrumentation around `_save_ratchet_state_to_db`:
 ```python
 import time
 start = time.perf_counter
 await session.commit
 elapsed_ms = (time.perf_counter - start) * 1000
 logger.info("Ratchet state save: %.2fms", elapsed_ms)
 ```

2. Run a load test: two users exchanging 1000 messages as fast as possible. Measure:
 - Average time per `_save_ratchet_state_to_db` call
 - Average time per `_load_ratchet_state_from_db` call
 - Total messages per second (end-to-end)
 - PostgreSQL connection pool utilization (`DB_POOL_SIZE` at `config.py`)

3. Implement Redis caching, repeat the same load test, compare.

**Redis cache schema:**
```
Key: ratchet:{user_id}:{peer_user_id}
Value: JSON serialized ratchet state
TTL: 300 seconds (auto-expire as safety net)
```

On each ratchet advance, write to Redis. Every 10 messages OR every 30 seconds, flush to PostgreSQL. On disconnect, flush immediately.

---

### WebSocket Load Testing

Use `locust` or `k6` to load test the WebSocket layer. Determine how many concurrent WebSocket connections a single server instance can handle.

**What to measure:**
1. Maximum concurrent WebSocket connections before memory exhaustion
2. Message throughput: messages per second at 100, 500, 1000, 5000 concurrent connections
3. Latency: p50, p95, p99 message delivery latency at various connection counts
4. Identify the bottleneck: Is it CPU (from encryption operations)? Memory (from connection pool at `websocket_manager.py`)? I/O (from SurrealDB writes)? Python GIL contention?

**Target:** Document the breaking point and propose a horizontal scaling strategy.

**Scaling considerations:**

The current architecture has a single `ConnectionManager` instance at `websocket_manager.py` holding all WebSocket connections in memory (`self.active_connections: dict[UUID, list[WebSocket]]`). This does not scale horizontally because connections on Server A are invisible to Server B.

To scale to multiple server instances:
1. Use Redis Pub/Sub for cross-instance message routing. When Server A needs to send a message to a user connected to Server B, it publishes to a Redis channel. Server B subscribes and forwards to the local WebSocket.
2. Store connection metadata in Redis: `{user_id: [server_a_instance_id, server_b_instance_id]}`
3. Use sticky sessions or consistent hashing to route WebSocket upgrade requests to the same server when possible (reduces cross-instance traffic)
4. Consider using a dedicated WebSocket gateway (like Centrifugo or Soketi) in front of the FastAPI application

**Load test script outline (k6):**
```javascript
import ws from 'k6/ws';
export default function {
 // The server expects a session cookie; load tests should sign in first
 // and pass the cookie via params.headers.Cookie.
 const url = 'ws://localhost:8000/ws';
 const params = { headers: { Cookie: 'chat_session=<session-token>' } };
 const res = ws.connect(url, params, function (socket) {
 socket.on('open', => {
 socket.send(JSON.stringify({
 type: 'encrypted_message',
 recipient_id: '...',
 room_id: '...',
 ciphertext: '...',
 nonce: '...',
 header: '...'
 }));
 });
 socket.on('message', (msg) => {});
 socket.setTimeout( => socket.close, 30000);
 });
}
```

Run with: `k6 run --vus 100 --duration 60s load_test.js`

---

## Security Challenges

---

### Implement Certificate Transparency for Identity Keys

Build a system where identity key changes are logged to a verifiable append-only log, similar to Certificate Transparency for TLS certificates. This prevents the server from silently swapping identity keys to perform a man-in-the-middle attack.

Currently, the server at `backend/app/services/prekey_service.py` serves prekey bundles. A compromised server could serve a fake identity key (its own), perform X3DH with both parties, and relay decrypted messages. The users would not know.

A key transparency log makes this detectable: every identity key is logged, and clients can audit the log to verify their key has not been replaced.

**Implementation sketch:**

1. Create a Merkle tree where each leaf is `(user_id, identity_key_hash, timestamp)`.
2. When a user registers or changes their identity key, append a new leaf to the tree.
3. Publish the Merkle root periodically (every hour) to a public log.
4. Clients download the Merkle root and verify their own key is included (Merkle inclusion proof).
5. If a client's key has been changed without their knowledge (the server swapped it), the Merkle proof will fail OR the client will see an unexpected key in the tree.

**The hard part:** Consistency. The server must prove that the tree is append-only (no entries have been removed or modified). This requires signed tree heads and consistency proofs between consecutive tree states.

**Research:** Google's Key Transparency project, CONIKS (Key Verification for Messaging), and Signal's key transparency deployment (announced 2023).

---

### Audit the Crypto Implementation

Perform a manual security audit of the X3DH and Double Ratchet implementations. This is not writing code. This is reading code critically.

**Audit checklist:**

1. **HKDF parameter usage** (`frontend/src/crypto/x3dh.ts`): Is the salt correct? Is the info string distinct between different uses? Are the output lengths appropriate?

2. **Nonce generation** (`frontend/src/crypto/double-ratchet.ts`): Is `os.urandom(AES_GCM_NONCE_SIZE)` called for every encryption? Is there any risk of nonce reuse?

3. **WebCrypto API usage** (`frontend/src/crypto/primitives.ts`): Is the `iv` parameter always fresh? Are `additionalData` bindings correct? Are key usages properly restricted?

4. **Timing side channels**: Look at `frontend/src/crypto/primitives.ts` (`constantTimeEqual`). Is this actually constant time in JavaScript? (Spoiler: the `if (a.length !== b.length) return false` is an early return that leaks length information. Is this a problem in context?)

5. **Random number generation**: Verify that all randomness comes from `os.urandom` (Python) or `crypto.getRandomValues` (JavaScript). Search for any use of `random` or `Math.random`.

6. **Key material in memory**: Are private keys ever logged? Search for `logger.debug` and `logger.info` calls that might print key material. Check that base64url-encoded keys are not accidentally included in error messages.

Write a report documenting your findings.

---

### Implement Sealed Sender

Build a system where the server does not know who sent a message, only who it is for. Signal implemented this as "Sealed Sender."

Currently, the WebSocket endpoint at `websocket.py` receives messages from authenticated users. The server knows `sender_id` (from the WebSocket connection) and `recipient_id` (from the message payload). It stores both in SurrealDB (`backend/app/services/message_service.py`).

With Sealed Sender, the sender identity is encrypted inside the E2E encrypted payload. The server only sees the recipient (needed for routing). The sender is revealed only after the recipient decrypts.

**Architecture:**
1. Outer layer: encrypt the routing envelope (which includes the real encrypted message) with the SERVER's public key. The server decrypts this to learn the recipient, but the sender field is absent or encrypted.
2. Inner layer: the E2E encrypted message as it works today, with sender identity inside the encrypted payload.

This requires the server to have its own keypair (separate from any user), and clients to know the server's public key.

**Implementation steps:**

1. Generate a server X25519 keypair on startup. Publish the server's public key at a well-known endpoint: `GET /api/.well-known/server-key`.

2. Modify the client message sending flow:
 - Construct the inner payload: the normal E2E encrypted message (ciphertext, nonce, header) PLUS `sender_id` in plaintext
 - Encrypt the inner payload with the intended recipient's ratchet (as currently done)
 - Construct the outer envelope: `{recipient_id: "bob-uuid", sealed_payload: "<encrypted inner>"}`
 - Encrypt the outer envelope with the server's public key (simple X25519 + AES-GCM)
 - Send only the outer ciphertext over the WebSocket

3. Modify the server routing:
 - Decrypt the outer envelope using the server's private key
 - Read `recipient_id` from the decrypted envelope
 - Forward `sealed_payload` to the recipient
 - The server never sees `sender_id`

4. Modify the recipient decryption:
 - Decrypt the sealed payload using the E2E ratchet
 - Extract `sender_id` from the decrypted content
 - Display the message with the correct sender attribution

**Limitation:** The server still knows the recipient (it needs to for routing). And it knows the sender's IP address and WebSocket connection. True sender anonymity requires additional measures like Tor or mix networks. Sealed Sender hides sender identity from the server's message logs, not from network-level observation.

**How to test:**
- Send a message between two users with Sealed Sender enabled
- Check the server's SurrealDB message records and verify `sender_id` is absent or encrypted
- Verify the recipient can still correctly identify the sender after decryption

---

## Contribution Challenges

---

### Write Property-Based Tests

Use Hypothesis (Python) to write property-based tests for the cryptographic implementations.

**Properties to verify:**

1. **X3DH symmetry:** For any two valid identity key pairs and any valid prekey bundle, `perform_x3dh_sender` and `perform_x3dh_receiver` produce the same `shared_key`. Reference: `frontend/src/crypto/x3dh.ts` and `frontend/src/crypto/x3dh.ts`.

2. **Double Ratchet round-trip:** For any sequence of plaintext messages in any order, encrypting with `encrypt_message` and decrypting with `decrypt_message` always returns the original plaintext. Reference: `frontend/src/crypto/double-ratchet.ts` and `frontend/src/crypto/double-ratchet.ts`.

3. **AES-GCM round-trip:** For any plaintext and any valid key, `aesGcmEncrypt` followed by `aesGcmDecrypt` returns the original plaintext. Reference: `frontend/src/crypto/primitives.ts`.

4. **No nonce reuse:** For N encryptions with the same key, all N nonces are distinct. (This should hold with overwhelming probability for random 12-byte nonces, but verify it empirically for N=10000.)

5. **Forward secrecy:** After advancing the ratchet, old message keys cannot be derived from the new state. Generate a ratchet state, encrypt a message, advance the ratchet 100 steps, then verify that the message key from step 0 cannot be recomputed from the state at step 100.

6. **Out-of-order decryption:** For any permutation of N messages, decrypting them in that permuted order produces the same set of plaintexts as decrypting in the original order. This tests the skipped message key logic at `frontend/src/crypto/double-ratchet.ts`.

**Hypothesis strategy example:**

```python
from hypothesis import given, strategies as st

@given(
 message_count=st.integers(min_value=1, max_value=50),
 delivery_order=st.permutations(range(50)) # random permutation
)
def test_out_of_order_delivery(message_count, delivery_order):
 """All messages decrypt correctly regardless of delivery order."""
 # Generate N messages
 # Encrypt them in order (advancing the sending ratchet)
 # Decrypt them in the shuffled order
 # Assert all plaintexts match the originals
```

**Where to put the tests:** The crypto property tests belong in the frontend Vitest suite next to `x3dh.test.ts` and `double-ratchet.test.ts`. Add a new file like `frontend/src/crypto/properties.test.ts` for randomized round-trip and tamper checks. Reserve `backend/tests/` for backend integration tests (auth, prekey storage, session enforcement).

---

### Add Formal Verification

Use a symbolic model checker (ProVerif or Tamarin Prover) to formally verify that the X3DH + Double Ratchet implementation satisfies:

1. **Secrecy:** An attacker who controls the network cannot learn message plaintext
2. **Authentication:** A message that decrypts successfully was sent by the claimed sender
3. **Forward secrecy:** Compromising long-term keys does not reveal past session keys
4. **Post-compromise security:** After an attacker loses access to session keys, future messages are secure again (this is the DH ratchet property)

This is a research-level challenge. Start by modeling X3DH alone before adding the Double Ratchet.

**Getting started with ProVerif:**

ProVerif uses a process calculus to model cryptographic protocols. You describe the protocol as a set of processes (Alice, Bob, Attacker) and the cryptographic primitives they use. ProVerif then explores all possible interleavings and attacker strategies to find attacks.

A minimal X3DH model in ProVerif would:
1. Define types for keys, nonces, and messages
2. Model the DH operations as `fun dh(skey, pkey): key` with the equation `dh(skA, pk(skB)) = dh(skB, pk(skA))`
3. Model HKDF as a random oracle: `fun kdf(key, key, key): key`
4. Define Alice's process: generate ephemeral key, compute DH1/DH2/DH3, derive shared key, encrypt message
5. Define Bob's process: receive ephemeral key, compute DH1/DH2/DH3, derive shared key, decrypt message
6. Query: `query attacker(message)` -- can the attacker learn the plaintext?

**Resources:**
- ProVerif manual: https://bblanche.gitlabpages.inria.fr/proverif/
- Tamarin Prover: https://tamarin-prover.com/
- "A Formal Security Analysis of the Signal Messaging Protocol" by Cohn-Gordon et al. (2017) -- this paper formally verified Signal using Tamarin

---

## Challenge Completion Tracker

Use this to track your progress. Check off each challenge as you complete it.

- [ ] Easy 1: Read Receipts
- [ ] Easy 2: Typing Indicators
- [ ] Easy 3: Message Timestamps and Ordering
- [ ] Easy 4: User Online Status
- [ ] Intermediate 5: Message Search (Encrypted)
- [ ] Intermediate 6: File Sharing (Encrypted)
- [ ] Intermediate 7: Multi-Device Sync
- [ ] Advanced 8: Group Encryption (Sender Keys)
- [ ] Advanced 9: Post-Quantum Key Exchange
- [ ] Advanced 10: Disappearing Messages
- [ ] Expert 11: Deniable Authentication
- [ ] Expert 12: Secure Backup and Recovery
