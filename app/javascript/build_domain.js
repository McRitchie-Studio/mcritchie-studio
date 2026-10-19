// The /build domain card's glow (app/views/build/cards/_address.html.erb;
// app/assets/tailwind/build_cards.css draws it). THE NAME FIELD IS THE SOURCE
// OF TRUTH: the chip whose name is exactly the field's value glows
// (aria-pressed="true"), no chip glows when it matches none, and Use Domain
// glows (data-build-glow="true") whenever the name could be claimed (the
// server's AppRequest::SUBDOMAIN_FORMAT, and not known to be taken) and is not
// the domain this request already holds (the card's data-chosen-name: that
// CTA is spent). The field is also kept sized to its value (its `size`), so
// the name and the suffix stay centred as one group.
//
// Pure (no imports, no document), so test/javascript/build_domain_test.js runs
// it against stand-in elements; app/javascript/build_chat.js calls it on every
// input, chip tap and availability answer.

// AppRequest::SUBDOMAIN_FORMAT: 3 to 30 of a-z, 0-9 and hyphens, starting and
// ending with a letter or number.
export const SUBDOMAIN_FORMAT = /^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$/;

// The field's value as the server will read it: a trailing hyphen the visitor
// is still typing past is not part of the name.
export function domainName(value) {
  return String(value || "").replace(/-+$/, "");
}

// The chip name the field matches exactly, or null.
export function matchingChip(value, names) {
  const name = domainName(value);
  return names.includes(name) ? name : null;
}

export function validDomain(value) {
  return SUBDOMAIN_FORMAT.test(domainName(value));
}

// Draws the card's glows from its field. `taken` is whether the live check
// last said this name is taken. Returns the glowing chip's name, or null.
export function syncDomainGlow(card, { taken = false } = {}) {
  const input = card.querySelector("[data-build-address-input]");
  if (!input) return null;
  const chips = Array.from(card.querySelectorAll("[data-build-domain-name]"));
  const match = matchingChip(input.value, chips.map((chip) => chip.dataset.buildDomainName));
  chips.forEach((chip) => chip.setAttribute("aria-pressed", String(chip.dataset.buildDomainName === match)));
  input.size = Math.max(input.value.length, 1);
  const submit = card.querySelector("[data-build-address-submit]");
  const held = (card.dataset?.chosenName || "") !== "" && domainName(input.value) === card.dataset.chosenName;
  if (submit) submit.dataset.buildGlow = String(validDomain(input.value) && !taken && !held);
  return match;
}

// A chip tap: the field takes the chip's name and the glow follows. The field
// is NOT focused, so a phone's keyboard does not pop up.
export function pickDomainChip(card, chip) {
  const input = card.querySelector("[data-build-address-input]");
  if (!input || chip.disabled) return null;
  input.value = chip.dataset.buildDomainName;
  return syncDomainGlow(card);
}
