# Sift — Client Revisions Plan

Post-build changes requested by the client (forwarded notes + screenshots),
triaged for launch. Build order: **quick wins first**, then the one launch-
critical security feature, then the big stuff after launch.

Legend: ✅ already exists (no work) · 🔨 build · 🕒 post-launch · ❓ needs a decision

---

## Phase 0 — Already in the app (confirm to client, zero build)

- ✅ **Commission balancing** — card trips auto-deduct commission via the
  Paystack split; cash trips become a driver **debt**. Already implemented.
- ✅ **Commission threshold in admin** — `Pricing → Cash-debt cap (R)` already
  sets the amount at which a driver is blocked. Already implemented.
- ✅ **Phone locked in Edit Profile** — phone is the login identity and is
  already not editable.

> These were misreadings of the existing app. We just show the client where
> they are.

---

## Phase 1 — Quick wins (do first, ~half a day total)

- [x] **1. Sift Bike category** 🔨 *(done — needs asset)*
  - New cheapest tier (0.7×, 1 seat, 2 min). Server + admin pricing know it.
  - **Pending:** drop the real bike PNG at `sift_app/assets/cars/bike.png`.

- [ ] **2. Show trip distance on Ride Options** 🔨
  - Distance (km) is already computed — just display it on the tier sheet.
  - No decision needed.

- [ ] **3. Tier seats + rename** 🔨 ❓
  - Sift Go: `4` → **2 or 3** ❓
  - Sift XL: `6` → show **4–7** (range) or a single number ❓
  - Sift Max → **"Premium" or "Comfort"** ❓ (id stays `max` so pricing/data
    don't break; only the display name changes)

- [ ] **4. Lock name in Edit Profile** 🔨
  - Make the name read-only (keep email editable). Phone already locked.
  - *(Editable phone = OTP re-verify flow → deferred, see Phase 3.)*

- [ ] **5. Cash receipt wording** 🔨
  - On **cash** receipts, reframe "Your earning" → show
    **"Cash collected R… · Commission owed –R…"** so drivers aren't confused
    (they physically hold the full fare and owe the commission).
  - Card receipts unchanged (commission really is netted out there).

- [ ] **6. Driver shown as a car marker** 🔨 ❓
  - **Decision:** is the gap on the **driver's own** home map, or where the
    **rider sees the driver** (matching/trip)? ❓

---

## Phase 2 — Launch-critical security feature

- [ ] **7. Rider ID + face verification before approval** 🔨
  - Riders currently auto-approve. Add: upload **ID + selfie**, gate the rider
    as `pending` until an admin approves (reuses the driver KYC + approval
    flow + the pending/rejected screens).
  - **Launch scope = MANUAL admin review** (free, staff eyeballs ID vs selfie).
  - 🕒 Automated face-match + liveness (Smile ID / AWS Rekognition) = phase 3.

---

## Phase 3 — Post-launch (big / not launch-blocking)

- [ ] **8. Sub-admins (LEAN role-based access)** 🕒 — *the final item*
  - Per-person admin logins (replace the single shared password; keep
    `ADMIN_PASSWORD` as the super-admin fallback).
  - One **role** per account → controls which **sidebar sections** they see:
    - Dispatcher → Live map, Rides, Parcels
    - Onboarding → Applications, Drivers
    - Support → Users, Rides
    - Finance → Finance, Pricing, Parcels
    - Super-admin → everything + an **Admins** management page
  - An **Admins** page (super-admin only) to add staff + assign a role.
  - **Deliberately cut:** granular per-button permissions, fleet
    data-scoping (Fleet = read-only role instead), separate auth system.
  - Satisfies the client's pasted 5-role spec in ~a day, not a week.

- [ ] **9. Automated rider face-match + liveness** 🕒 — phase 2 of item 7.

- [ ] **10. Editable phone number** 🕒 — needs OTP re-verification of the new
  number + account migration. Defer unless the client insists.

---

## Open decisions to confirm before building Phase 1

- [ ] Sift Go seats: **2 or 3**?
- [ ] Sift XL: display **"4–7"** range, or a single number?
- [ ] Sift Max new name: **Premium** or **Comfort**?
- [ ] Driver-as-car marker: **own map** or **rider's view**?
- [ ] Cash-debt block: keep at a **cap** (current) or block at **any** debt?
- [ ] Bike PNG asset — pending from client.

---

## Recommended order

1. Phase 1 quick wins (batch them, one deploy).
2. Phase 2 manual rider verification.
3. **Launch.**
4. Phase 3: sub-admins (lean) → automated face-match → editable phone.
