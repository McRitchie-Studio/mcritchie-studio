// Minimal Solana/Phantom wallet sign-in for the hub login page.
//
// Web3 is the SECONDARY auth path in McRitchie Studio (vs. magic-link / Google),
// so this is a deliberately small, single-wallet (Phantom) connect+sign flow —
// not turf-monster's full multi-wallet Connect-Wallet modal. It mirrors the
// proven SIWS message shape so the server-side Solana::AuthVerifier (host bind +
// nonce) accepts the signature.
//
// On success the server returns { redirect }; we navigate there.
//
// NOTE: when this is lifted into the engine (Phase 3, shared with turf), the
// base58 encoder + the Phantom provider abstraction become the shared modules.

const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function encodeBase58(bytes) {
  const digits = [0];
  for (let i = 0; i < bytes.length; i++) {
    let carry = bytes[i];
    for (let j = 0; j < digits.length; j++) {
      carry += digits[j] << 8;
      digits[j] = carry % 58;
      carry = (carry / 58) | 0;
    }
    while (carry) { digits.push(carry % 58); carry = (carry / 58) | 0; }
  }
  let str = "";
  for (let i = 0; i < bytes.length && bytes[i] === 0; i++) str += "1";
  for (let i = digits.length - 1; i >= 0; i--) str += B58_ALPHABET[digits[i]];
  return str;
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || "";
}

window.studioWalletLogin = async function () {
  const provider = window.phantom?.solana || (window.solana?.isPhantom ? window.solana : null);
  if (!provider) {
    window.open("https://phantom.app/", "_blank");
    throw new Error("Phantom wallet not found");
  }

  const resp = await provider.connect();
  const pubkeyB58 = resp.publicKey.toBase58();

  const { nonce } = await (await fetch("/auth/solana/nonce")).json();
  const domain = window.location.host;
  const message =
    domain + " wants you to sign in with your Solana account:\n" +
    pubkeyB58 + "\n\nSign in to McRitchie Studio\n\nNonce: " + nonce;

  const signed = await provider.signMessage(new TextEncoder().encode(message), "utf8");
  const signatureB58 = encodeBase58(signed.signature);

  const result = await (await fetch("/auth/solana/verify", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify({ message: message, signature: signatureB58, pubkey: pubkeyB58 }),
  })).json();

  if (result && result.success) {
    window.location = result.redirect || "/";
  } else {
    throw new Error((result && result.error) || "Wallet sign-in failed");
  }
};
