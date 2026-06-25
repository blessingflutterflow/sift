/**
 * Thin wrapper over the Paystack REST API. Every call uses the secret key,
 * which lives in Functions Secrets (PAYSTACK_SECRET_KEY) — never in source.
 *
 * Paystack works in minor units: ZAR amounts are passed as cents (× 100).
 * Helpers here take ZAR and convert at the boundary so callers stay in rands.
 */
const { defineSecret } = require("firebase-functions/params");

const PAYSTACK_SECRET_KEY = defineSecret("PAYSTACK_SECRET_KEY");

const BASE = "https://api.paystack.co";

/** ZAR → cents (Paystack minor unit). */
const toCents = (zar) => Math.round((Number(zar) || 0) * 100);
/** cents → ZAR. */
const toZar = (cents) => Math.round((Number(cents) || 0)) / 100;

async function call(method, pathname, body) {
  const res = await fetch(`${BASE}${pathname}`, {
    method,
    headers: {
      Authorization: `Bearer ${PAYSTACK_SECRET_KEY.value()}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json.status === false) {
    const msg = json.message || `Paystack ${method} ${pathname} failed`;
    const err = new Error(msg);
    err.paystack = json;
    err.httpStatus = res.status;
    throw err;
  }
  return json.data;
}

/**
 * Start a checkout (card vault or one-off). `amount` in ZAR. Returns
 * { authorization_url, access_code, reference }.
 */
function initializeTransaction({ email, amountZar, reference, metadata, channels }) {
  return call("POST", "/transaction/initialize", {
    email,
    amount: toCents(amountZar),
    reference,
    metadata,
    channels: channels || ["card"],
    currency: "ZAR",
  });
}

/** Server-side charge of a previously-vaulted card (no UI). */
function chargeAuthorization({
  email,
  authorizationCode,
  amountZar,
  reference,
  subaccount,
  transactionChargeZar,
  metadata,
}) {
  return call("POST", "/transaction/charge_authorization", {
    email,
    authorization_code: authorizationCode,
    amount: toCents(amountZar),
    reference,
    currency: "ZAR",
    metadata,
    // Split: driver's subaccount receives the fare minus our commission.
    // bearer 'account' = the PLATFORM pays Paystack's processing fee (D2),
    // so the driver's settlement is exactly fare − commission.
    subaccount: subaccount || undefined,
    transaction_charge:
      transactionChargeZar != null ? toCents(transactionChargeZar) : undefined,
    bearer: subaccount ? "account" : undefined,
  });
}

/** Verify a transaction by reference (webhook backstop). */
function verifyTransaction(reference) {
  return call("GET", `/transaction/verify/${encodeURIComponent(reference)}`);
}

/** Refund a transaction (full or partial ZAR amount). */
function refund({ reference, amountZar }) {
  return call("POST", "/refund", {
    transaction: reference,
    amount: amountZar != null ? toCents(amountZar) : undefined,
  });
}

/** Create a driver payout subaccount. `percentageCharge` is the PLATFORM %. */
function createSubaccount({ businessName, bankCode, accountNumber, percentageCharge }) {
  return call("POST", "/subaccount", {
    business_name: businessName,
    settlement_bank: bankCode,
    account_number: accountNumber,
    percentage_charge: percentageCharge,
  });
}

/** List ZA settlement banks (code + name). */
function listBanks() {
  return call("GET", "/bank?currency=ZAR&country=south africa");
}

/** Resolve an account number → account holder name. */
function resolveAccount({ accountNumber, bankCode }) {
  return call(
    "GET",
    `/bank/resolve?account_number=${encodeURIComponent(
      accountNumber
    )}&bank_code=${encodeURIComponent(bankCode)}`
  );
}

module.exports = {
  PAYSTACK_SECRET_KEY,
  toCents,
  toZar,
  initializeTransaction,
  chargeAuthorization,
  verifyTransaction,
  refund,
  createSubaccount,
  listBanks,
  resolveAccount,
};
