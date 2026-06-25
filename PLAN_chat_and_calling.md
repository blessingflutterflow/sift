# Build Plan — In-App Chat (#8) & Masked Calling (#9)

Contract deliverable #11: *"In-App Chat & Masked Calling System."*
Prepared for the next build session. Both replace/extend the current raw `tel:`
call buttons on the rider (`matching_screen.dart`) and driver
(`driver_trip_screen.dart`) trip screens.

---

## #8 — In-App Chat (rider ↔ driver)

**Approach:** Firestore-backed real-time messaging scoped to a ride. No new
infrastructure — reuses Firestore streams + the existing FCM `push()` helper in
`functions/notifications.js`. Chat is live only while a ride is active
(accepted → in_progress); afterwards it becomes read-only history.

### Data model
`rides/{rideId}/messages/{messageId}`:
- `senderId` (uid)
- `senderRole` — `'rider' | 'driver'`
- `text` (string, 1–500 chars, trimmed)
- `createdAt` (serverTimestamp)

Denormalized on the ride doc (for unread badges, written by a function):
- `lastMessageAt`, `unreadForRider`, `unreadForDriver`

### Firestore rules (add to `firestore.rules`)
```
match /rides/{rideId}/messages/{messageId} {
  function ride() { return get(/databases/$(database)/documents/rides/$(rideId)).data; }
  allow read: if isSignedIn()
    && (ride().riderId == request.auth.uid
        || ride().driverId == request.auth.uid
        || isAdmin());
  allow create: if isSignedIn()
    && request.resource.data.senderId == request.auth.uid
    && (ride().riderId == request.auth.uid || ride().driverId == request.auth.uid)
    && ride().status in ['accepted','arriving','arrived','in_progress']
    && request.resource.data.text is string
    && request.resource.data.text.size() > 0
    && request.resource.data.text.size() <= 500
    && request.resource.data.keys().hasOnly(['senderId','senderRole','text','createdAt']);
  // Messages are immutable — no client update/delete.
}
```
(Each `get()` costs one document read; acceptable at chat volume.)

### Backend (`functions/`)
- `onMessageCreated` — Firestore trigger on `rides/{rideId}/messages/{messageId}`:
  - FCM push to the *other* party ("New message from your driver/rider", with
    `type: 'chat'`, `rideId`), reusing `push()`.
  - Increment `unreadForRider`/`unreadForDriver` and set `lastMessageAt` on the
    ride (transaction).
- Optional `markChatRead` callable (or client-side rule-limited write) to reset
  the unread counter when a party opens the chat.

### Client (`sift_app/lib/`)
- `data/repositories/chat_repository.dart` — `streamMessages(rideId)`,
  `sendMessage(rideId, text, role)`.
- `features/chat/chat_screen.dart` — message list (own = brand-orange bubble
  right, other = grey left), text field + send, empty state, auto-scroll,
  disabled input once the ride ends.
- Entry points:
  - Rider: chat icon in the driver card on `matching_screen.dart`
    (next to the share + call buttons), with an unread dot.
  - Driver: chat icon on `driver_trip_screen.dart`.
- Push tap handling: a `type: 'chat'` notification deep-opens the chat for that
  ride (extend the existing `notification_service.dart`).

### Dependencies
None new (Firestore + existing FCM). Reuse the app's date formatting.

### Effort
Medium — 1 screen, 1 repository, 1 function, rules block, 2 entry buttons.
~Half a day. No external accounts or cost.

---

## #9 — Masked Calling

**What it means:** neither party sees the other's real number; calls route
through a **proxy number**. This is NOT purely a code task — it needs a
telephony provider and a **paid, voice-capable phone number**. That provisioning
(and, for SA local numbers, regulatory steps) is the lead-time item — decide it
before coding.

### Provider decision (DO THIS FIRST)
| Option | Pros | Cons |
|---|---|---|
| **Twilio** (recommended) | Already in the stack (we use Twilio Verify for OTP); one account, one set of secrets; great docs | SA *local* numbers need a regulatory bundle; may use a non-geographic/managed number; per-minute voice cost |
| Africa's Talking | Strong Africa/SA voice + local-number fit | New integration, new account/secrets |

Recommendation: **Twilio**, since credentials + billing already exist.

**Costs to expect:** one voice number (~$1–15/mo) + per-minute call charges.
Number provisioning can take time (esp. SA regulatory) — start early.

### Architecture (Twilio, single shared proxy number)
1. Provision **one** voice-capable Twilio number = the proxy (store as a Functions secret `TWILIO_PROXY_NUMBER`).
2. While a ride is active, the pair (`riderPhone`, `driverPhone`) is known on the
   ride doc. Direction is decided by **who is calling** the proxy.
3. **Click-to-call:** the app dials the **proxy number** (not the counterpart).
4. Twilio hits a webhook → we bridge to the correct counterpart, with
   `callerId = proxy number`, so the callee sees the proxy, not the real caller.
   Both sides masked.

### Backend (`functions/`)
- `voiceWebhook` (`onRequest`, returns TwiML):
  - Look up the inbound caller (`From`) against active rides:
    - if `From == riderPhone` → `<Dial callerId=PROXY><Number>driverPhone</Number></Dial>`
    - if `From == driverPhone` → bridge to `riderPhone`
    - else → polite "no active trip" message + hang up.
  - Lookup source: a small `call_sessions` mapping (`{riderPhone, driverPhone, rideId, expiresAt}`)
    written on `acceptRide` and cleared on `completeRide`/`cancelRide`, OR a
    direct query of the active ride by phone (indexed). Mapping collection is
    cleaner and avoids exposing the ride query.
- Configure the Twilio number's Voice webhook URL to point at `voiceWebhook`.

### Client (`sift_app/lib/`)
- Replace the call buttons' target on `matching_screen.dart` and
  `driver_trip_screen.dart`: dial `TWILIO_PROXY_NUMBER` (delivered to the client
  via `getPricing`/a config doc, or returned by a tiny callable) instead of the
  counterpart's real number.
- **Privacy follow-through:** once masking is live, stop sending `riderPhone` /
  `driverPhone` to the *other* client. They're currently on the ride doc and
  used for the raw `tel:`. After masking, clients only need the proxy number;
  keep the real numbers server-side (and for the SOS sheet relay, which is fine).

### Security / edges
- Only bridge when a ride involving that phone pair is currently active.
- Expire `call_sessions` on ride end so an old link can't reconnect strangers.
- App Check / secret-guarded webhook; verify Twilio signature on the webhook.
- Fallback: if masking is unavailable (no active session), show "calling
  unavailable" rather than leaking the real number.

### Effort
- Code (webhook + session writes + client swap): ~half a day.
- **Provider + number provisioning: the real lead time** (account is ready;
  buying/verifying a voice number — possibly SA regulatory — can take days).

---

## Suggested order for the session
1. **Build #8 (chat)** first — self-contained, no external dependency, fully
   shippable in a session.
2. **Kick off the Twilio number purchase** at the start of the day so it's ready.
3. **Build #9 (masked calling)** once the number is provisioned.

## Open decisions to confirm before starting #9
- [ ] Provider: **Twilio** (recommended) or Africa's Talking?
- [ ] Approved to purchase a voice number + per-minute spend?
- [ ] One shared proxy number (cheap, map by phone pair) — confirm OK for MVP.
