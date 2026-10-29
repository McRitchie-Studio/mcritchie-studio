// The /books review page's purpose field: shown, and submitted, only while a
// distribution is picked (task mack-review-page-polish).
//
// Usage (app/views/books/index.html.erb), one per line's form:
//   <form data-books-line>
//     <select data-books-category> <option data-kind="distribution"> … </select>
//     <label data-books-purpose hidden> <input name="purpose" disabled> </label>
//   </form>
//
// The field is rendered hidden and disabled, so with JavaScript off (or before
// this runs) no purpose can be typed beside a fee. Books::Classify refuses a
// stray purpose anyway; this only keeps the form from offering one.

export function purposeShown(kind) {
  return kind === "distribution";
}

// Shows or hides one form's purpose field to match its category pick.
export function syncPurpose(form) {
  const select = form.querySelector("[data-books-category]");
  const field = form.querySelector("[data-books-purpose]");
  if (!select || !field) return;
  const option = select.selectedOptions && select.selectedOptions[0];
  const shown = purposeShown(option ? option.getAttribute("data-kind") : null);
  field.hidden = !shown;
  field.querySelectorAll("input").forEach((input) => { input.disabled = !shown; });
}

export function installBooksPurpose(doc = document) {
  doc.querySelectorAll("[data-books-line]").forEach(syncPurpose);
}

if (typeof document !== "undefined") {
  document.addEventListener("change", (event) => {
    const select = event.target.closest && event.target.closest("[data-books-category]");
    const form = select && select.closest("[data-books-line]");
    if (form) syncPurpose(form);
  });
  document.addEventListener("turbo:load", () => installBooksPurpose());
  if (document.readyState !== "loading") installBooksPurpose();
}
