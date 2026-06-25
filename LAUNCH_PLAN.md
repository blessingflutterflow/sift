# Sift — Launch Execution Plan (MVP → viable business)

One-shot execution plan. When every box here is done, the app is launchable.
Scope: Android-first, South Africa, ZAR, Paystack.

---

## 0. Decisions to confirm before execution (defaults applied if unchanged)

| # | Decision | Default |
|---|----------|---------|
| D1 | Commission per trip | **20%** of final fare (admin-configurable) |
| D2 | Who bears Paystack processing fees | **Platform** (out of commission) — drivers see clean math |
| D3 | Cash trips at launch | **Yes** (SA reality) — commission tracked as driver debt |
| D4 | Charge timing | **At trip completion** (final fare = quoted + waiting fee), saved card charged server-side |
| D5 | Waiting fee | Free 5 min after arrival, then **R1.50/min** (config) |
| D6 | Cancellation fee | **R25** if rider cancels >2 min after accept or after arrival; credited to driver minus commission |
| D7 | Cash-debt cap | Driver blocked from going online when commission debt > **R300** until paid in-app |
| D8 | Payout rail | **Paystack subaccounts + transaction splits** (auto-settlement to driver bank T+1/T+2, no manual payouts) |

---

## 1. Money architecture (Paystack)

**Principle: no client ever computes or writes money fields. All Paystack calls live in Cloud Functions (secret key in Functions Secrets). Clients render; webhook is the source of truth.**

### 1.1 Card vault (rider)
- `initCardSetup` callable → Paystack *Initialize Transaction* (R1.00, channels `['card']`) → app opens `authorization_url` in in-app WebView → on `charge.success` webhook, store `authorization_code`, `last4`, `brand`, `exp` in `users/{uid}/payment_methods/{id}`; auto-refund the R1 (or make first trip the vaulting transaction).
- Future trips: server-side *Charge Authorization* — no UI.
- 3DS/OTP failures → ride flips to `payment_due`; rider sees "Pay now" (fresh checkout link); **new ride requests blocked while a debt exists**.

### 1.2 Driver subaccounts (payout)
- New **Payout details** step in driver onboarding: bank (from Paystack *List Banks ZA*), account number → server `resolveBank` callable verifies account name.
- On admin approval → function creates **Paystack subaccount**, stores `subaccountCode` on `applications/{uid}`.
- Every card charge passes `subaccount` + `transaction_charge = commission` (cents) → Paystack auto-splits: driver's share settles to their bank on Paystack's schedule. No transfers code, no float management.

### 1.3 Trip settlement flow
- `completeRide` **callable** (replaces the driver's direct `status=completed` write):
  1. Validates caller is assigned driver and status is `in_progress`.
  2. Computes final fare server-side: `quotedFare + waitFee` (wait = minutes beyond free window between `arrivedAt`→`startedAt`).
  3. Card: *Charge Authorization* with split → on webhook `charge.success`: `paymentStatus=paid`, write `transactions/{ref}` + ledger entries. On failure: `paymentStatus=due` + rider block.
  4. Cash: `paymentStatus=cash`; ledger entry `cash_commission_due` (negative for driver).
- `cancelRide` upgrade: applies D6 fee when conditions met (charge card / add to rider debt), driver credited via ledger.
- `payDebt` callable (driver pays cash commission; rider settles `payment_due`).

### 1.4 Webhook + ledger
- `paystackWebhook` (HTTPS function): signature-verified, **idempotent** (keyed on Paystack reference), handles `charge.success`, `refund.processed`, transfer/settlement events. Writes `transactions/{ref}` and updates the ride + ledgers transactionally.
- `ledgers/{driverUid}` (running `balance`) + `ledgers/{driverUid}/entries/{id}`: `trip_earning | cash_commission_due | debt_payment | cancel_fee | adjustment(admin)`. Every cent visible to admin and driver.

### 1.5 Fare engine goes server-side (CRITICAL — currently client computes fare)
- `config/pricing` doc: `fareBase, farePerKm, farePerMin?, tierMultipliers{go,xl,max}, commissionPct, waitFreeMin, waitPerMin, cancelFee, cashEnabled, minVersion`.
- `requestRide` becomes a **callable** (App Check enforced): validates input, computes `quotedFare` from config + route distance, creates the ride doc. Client fare display becomes read-only.
- Admin edits pricing live from the dashboard.

---

## 2. Security lockdown (precondition for real money)

- **Firestore rules — rides**: field-level validation. Driver may only write `status` (legal transitions, not `completed` — that's the callable), telemetry fields, `driverRating`. Rider may only write `riderRating`. Money fields (`fare, finalFare, commission, paymentStatus, ...`) writable by Admin SDK only.
- App Check enforced on **all** callables. NOTE (2026-06-12): `enforceAppCheck` was turned **OFF** on `sendOtp`/`verifyOtp` for the sideload-testing phase (compensated by a per-phone send throttle). **Must be re-enabled at launch**, when builds distribute via the Play internal testing track and Play Integrity attests automatically.
- Maps key: currently shipped in source for REST Directions/Places (can't be app-restricted). Add `getRoute` + `placesAutocomplete` **proxy functions** (App Check-gated, key in secrets); Android Maps SDK key restricted by package + SHA-1. Set quota alerts.
- `serviceAccountKey.json` in sift_admin → move to env var, add to .gitignore, **rotate the key**.

---

## 3. Remaining app screens

### Rider
| Screen | Notes |
|---|---|
| Payment methods | list/add/remove cards, set default; "Cash" toggle |
| Add card (WebView) | Paystack checkout → success deep-return |
| Payment selector on Ride Options | replaces hardcoded "Cash · Personal trip" row |
| Outstanding payment banner + Pay now | blocks new requests while `payment_due` |
| Trip history + Receipt detail | fare breakdown: base/distance/wait/total, method, ref |
| Saved places (Home/Work + recents) | replaces hardcoded London placeholders(!) on Home; recents from past rides |
| Edit profile | name/email |
| Call driver button | `tel:` — numbers already on the ride doc |
| Safety: share trip + emergency call | share text (driver, plate, live status), dial emergency |

### Driver
| Screen | Notes |
|---|---|
| Earnings dashboard | today/week totals, per-trip list, card vs cash, commission shown |
| Cash commission debt + Pay now | drives the D7 block |
| Payout details (onboarding step + editable) | bank select, account resolve, subaccount status |
| Trip history | with earnings per trip |
| Edit vehicle/profile | re-upload docs; doc expiry warnings |
| Call rider button | on trip screen |

### Both
- Trip-state push notifications (below) and empty/error states everywhere.

---

## 4. Reliability layer (a ride app that misses offers is dead)

- **FCM** (`firebase_messaging`): token registry on `users/{uid}`. Functions send: new offer → driver (high-priority data+notification), status changes (accepted/arriving/arrived/started/completed/cancelled) → rider, approval decisions → driver, payment events → both.
- **Driver background tracking**: geolocator Android **foreground service** (`ForegroundNotificationConfig`) while online/on-trip, so GPS survives screen-off. Manifest: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS` (runtime prompt on 13+).
- Offer flow hardening: offer push wakes driver app; offer card already has the 15s countdown.
- `driver_locations` rules: rides need driver reads — already fine; admin map unchanged.

---

## 5. Admin = mission control

| Page | Capabilities |
|---|---|
| Dashboard (KPIs) | rides today/week, GMV, commission earned, completion %, online drivers, active rides now |
| Rides | live rides (map + status), full history, filters; detail = timeline + route + money breakdown; force-cancel |
| Transactions | all Paystack charges/refunds w/ refs + statuses; **refund button** (calls Refund API); reconciliation view of webhook vs expected |
| Driver finance | per-driver ledger, balance, subaccount status, manual `adjustment` entries (waive/charge), settle cash debt |
| Pricing config | edit `config/pricing` live (with confirmation + audit) |
| Users | block/unblock rider & driver (blocks enforced in callables/rules), ratings overview |
| Applications | existing review flow + payout-details verification + doc expiry tracking |
| Audit log | `admin_audit/{id}` — every admin mutation (who/what/before/after) |

---

## 6. Hardening & launch ops

- Crashlytics + Analytics (funnel: request→match→complete).
- Firestore **indexes** for: rider history, driver history, ledger queries, admin ride filters, transactions by date.
- Version gate: `minVersion` in config → force-update screen.
- POPIA-compliant privacy policy + account-deletion path (Play requirement).
- Play Store: listing assets, data-safety form, closed-track rollout.
- Twilio/Paystack production keys via Functions Secrets; webhook URL registered in Paystack dashboard (live + test).

---

## 7. Execution order (single run, each phase verifiable)

| Phase | Work | Size |
|---|---|---|
| **P1** ✅ | Server money core: pricing config seeded, fare engine (`pricing.js`), `completeRide` + `getPricing` callables, authoritative fare in `onRideRequested`, cash ledger, hardened rules staged (`firestore.rules.hardened` — **deploy pending device install**). Key rotation still TODO. | L |
| **P2** ✅ | Backend DEPLOYED (`paystack.js`, `payments.js`: signed+idempotent webhook, `initCardSetup`, `listBanks`/`resolveBankAccount`, subaccount-on-approval, `refundTransaction`; charge-with-split in `completeRide`; platform bears fees). Secret stored. Webhook URL: `https://europe-west1-sift-d1cf4.cloudfunctions.net/paystackWebhook` — **user must register it in Paystack dashboard (test mode)**. Client card-vault WebView + debt/cancel-fee UI fold into P3/P4. Rotate this test key before going live (it was shared in chat). | L |
| **P3** ✅ | Payments UX (PaymentMethodsScreen + checkout WebView, pay-with selector, paid/charging/due + Pay-now, `initDebtPayment`); trip history + receipts (role-aware, fare/earning breakdown, indexes deployed); saved places (Home/Work slots + customs, replaces hardcoded placeholders on home + destination); profile edit; call buttons both sides (`acceptRide` now stamps driverPhone). Safety share-trip deferred to P7 polish. | M |
| **P4** ✅ | Driver money: EarningsScreen (today/week totals, ledger activity, debt card + in-app settlement via `initDriverDebtPayment`), PayoutDetailsScreen (live ZA bank list, server-verified account via `savePayoutDetails`, subaccount auto-created — works pre- or post-approval), go-online debt-cap gate (D7), driver history shares TripHistoryScreen. Payout capture is post-onboarding (menu/banner) rather than an onboarding step — acceptable for launch. | M |
| **P5** ✅ | FCM live: `onRideNotify` (offer→driver high-priority; accepted/arriving/arrived/completed/cancelled/expired→rider; payment paid/due→rider) + `onApplicationNotify` (approval decisions), dead-token pruning. Client: firebase_messaging, token registry on `users/{uid}.fcmTokens` (registered on home screens, removed on sign-out, rotation-followed). Android foreground-service GPS for both driver streams (online idle + on-trip) with persistent notification + wake lock — tracking survives screen-off. Manifest: POST_NOTIFICATIONS, FOREGROUND_SERVICE(_LOCATION), WAKE_LOCK. | M |
| **P6** ✅ | Admin suite live: Rides (KPI strip — today/week/GMV/commission/completion/online — filters, detail w/ money + timeline + force-cancel + refund), Finance (driver ledgers w/ manual adjustments, all Paystack transactions w/ refund), Pricing live editor, Audit log (every admin mutation), Users block/unblock (enforced in dispatch: blocked rider's request expires, blocked driver can't accept). `.env.local` carries PAYSTACK_SECRET_KEY for refunds (set it in Vercel env for prod). | L |
| **P7** ✅ | **Hardened rules DEPLOYED** (money fields admin-only, driver writes field-locked, client can't set status=completed; fixed post-trip-rating edge). Maps key OUT of the APK — `getRoute`/`placesAutocomplete`/`placeDetails` proxy functions (auth-required, MAPS_API_KEY in Secret Manager). Crashlytics wired (release-only). Force-update gate off `config/pricing.minVersion`. `deleteAccount` callable + menu entry (Play requirement). All functions on Node 22 (20 was deprecated). | M |
| **P8** 🟡 | Manual E2E pass done by owner (auth, dispatch, tracking, card+cash money loops, debt, push, admin). Remaining at launch: re-run matrix below on release builds via Play internal track. | M |

---

## LAUNCH-DAY RUNBOOK (the only things standing between this and the store)

1. **Paystack → live mode**: business verification in Paystack dashboard → generate LIVE keys → `firebase functions:secrets:set PAYSTACK_SECRET_KEY` with the live key (also ROTATES the test key, which was shared in chat) → update `sift_admin` env → register the same webhook URL under live mode settings.
2. **App Check back ON**: `enforceAppCheck: true` on `sendOtp`/`verifyOtp` in `functions/index.js` → deploy. Only works once builds install via Play (internal testing counts).
3. **Release build**: `flutter build appbundle --release` with a proper signing key (`key.properties`); bump `version:` in pubspec + `AppConfig.appVersion` together.
4. **Play Console**: listing assets, data-safety form (location, phone, payment info collected), privacy policy URL (POPIA), account-deletion URL/in-app declaration → internal testing track first.
5. **Maps SDK key**: restrict the manifest key (Android apps → package `za.co.sift.app` + SHA-1) in Google Cloud console; the REST key now lives server-side only.
6. **Admin to Vercel** (or keep local): set `FIREBASE_SERVICE_ACCOUNT` + `PAYSTACK_SECRET_KEY` env vars; rotate the local `serviceAccountKey.json` after.
7. **Twilio**: move from trial (if applicable) + confirm Verify service is production-ready; keep Fraud Guard on.
8. **minVersion discipline**: any breaking contract change → bump `config/pricing.minVersion` from the admin Pricing page... old builds hit the update wall instead of corrupting data.
9. Re-run the §E2E matrix on the Play-installed release build before opening to the public.

### E2E acceptance matrix (Paystack test mode, 2 devices)
1. Card trip happy path: request → match → track → arrive (wait <5min) → complete → card auto-charged → split visible → receipt + earnings correct.
2. Card trip with waiting fee (>5 min wait) → fare = quoted + wait fee.
3. Card charge fails → ride `payment_due`, rider blocked, "Pay now" clears it.
4. Cash trip → commission debt appears; debt > cap blocks going online; in-app debt payment unblocks.
5. Rider cancels late → cancel fee charged, driver credited.
6. Offer reaches a backgrounded driver via push; tracking survives screen-off.
7. Admin: refund a charge, adjust a ledger, edit pricing → next quote reflects it; audit entries exist.
8. Security: rider/driver cannot mutate money fields or skip status transitions (rules tests).

---

## Explicitly deferred (post-launch backlog)
Scheduled rides, promo codes, in-app chat, surge pricing, driver heatmaps, multi-stop, iOS release, number masking, automated document-expiry enforcement, email receipts.
