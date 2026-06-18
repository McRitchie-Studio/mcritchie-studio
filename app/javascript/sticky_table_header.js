const MANUAL_TABLE_SELECTOR = "table[data-sticky-table-header]";
const AUTO_TABLE_SELECTOR = "table";
const SKIP_CONTAINER_SELECTOR = "[data-sticky-table-skip]";

let stickyTables = [];
let scheduled = false;
let bootScheduled = false;
let navResizeObserver = null;
let tableMutationObserver = null;

function navOffset() {
  const raw = getComputedStyle(document.documentElement).getPropertyValue("--nav-h");
  return Number.parseFloat(raw) || 0;
}

function scheduleUpdate() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    stickyTables.forEach((stickyTable) => stickyTable.update());
  });
}

function scheduleBoot() {
  if (bootScheduled) return;
  bootScheduled = true;
  requestAnimationFrame(() => {
    bootScheduled = false;
    bootStickyTables();
  });
}

class StickyTableHeader {
  constructor(table) {
    this.table = table;
    this.prepareTable();
    this.scroller = table.closest("[data-sticky-table-scroll]") || table.parentElement;
    this.cloneShell = document.createElement("div");
    this.cloneShell.className = "sticky-table-header-clone";
    this.cloneShell.setAttribute("aria-hidden", "true");

    this.cloneTable = document.createElement("table");
    this.cloneTable.className = table.className;
    this.cloneTable.innerHTML = table.tHead ? table.tHead.outerHTML : "";
    this.cloneShell.appendChild(this.cloneTable);
    document.body.appendChild(this.cloneShell);

    this.scroller?.addEventListener("scroll", scheduleUpdate, { passive: true });
  }

  prepareTable() {
    this.table.classList.add("sticky-data-table");
    if (!this.table.hasAttribute("data-sticky-table-header")) {
      this.table.setAttribute("data-sticky-table-header", "auto");
    }

    const scroller = this.table.closest("[data-sticky-table-scroll]") || this.table.parentElement;
    if (scroller && !scroller.hasAttribute("data-sticky-table-scroll")) {
      scroller.setAttribute("data-sticky-table-scroll", "auto");
    }
  }

  destroy() {
    this.scroller?.removeEventListener("scroll", scheduleUpdate);
    this.cloneShell.remove();
  }

  syncColumnWidths() {
    const originalCells = this.table.tHead?.querySelectorAll("th") || [];
    const cloneCells = this.cloneTable.tHead?.querySelectorAll("th") || [];
    originalCells.forEach((cell, index) => {
      if (!cloneCells[index]) return;
      cloneCells[index].style.width = `${cell.getBoundingClientRect().width}px`;
    });
  }

  update() {
    if (!document.body.contains(this.table) || !this.table.tHead || !this.scroller) {
      this.destroy();
      stickyTables = stickyTables.filter((stickyTable) => stickyTable !== this);
      return;
    }

    const offset = navOffset();
    const headerRect = this.table.tHead.getBoundingClientRect();
    const tableRect = this.table.getBoundingClientRect();
    const scrollerRect = this.scroller.getBoundingClientRect();
    const cloneHeight = headerRect.height || this.cloneShell.getBoundingClientRect().height;
    const active = headerRect.top <= offset && tableRect.bottom > offset;

    if (!active) {
      this.cloneShell.style.display = "none";
      this.table.removeAttribute("data-sticky-table-active");
      return;
    }

    this.syncColumnWidths();

    const top = Math.min(offset, tableRect.bottom - cloneHeight);
    const translateX = tableRect.left - scrollerRect.left;

    this.cloneShell.style.display = "block";
    this.cloneShell.style.left = `${scrollerRect.left}px`;
    this.cloneShell.style.top = `${top}px`;
    this.cloneShell.style.width = `${scrollerRect.width}px`;
    this.cloneShell.style.height = `${cloneHeight}px`;
    this.cloneTable.style.width = `${tableRect.width}px`;
    this.cloneTable.style.transform = `translateX(${translateX}px)`;
    this.table.setAttribute("data-sticky-table-active", "true");
  }
}

function bootStickyTables() {
  startTableObserver();

  if (navResizeObserver) navResizeObserver.disconnect();
  if (window.ResizeObserver) {
    const header = document.querySelector("header");
    if (header) {
      navResizeObserver = new ResizeObserver(scheduleUpdate);
      navResizeObserver.observe(header);
    }
  }

  stickyTables.forEach((stickyTable) => stickyTable.destroy());
  stickyTables = stickyTableCandidates().map((table) => new StickyTableHeader(table));
  scheduleUpdate();
}

function startTableObserver() {
  if (!window.MutationObserver || tableMutationObserver || !document.body) return;

  tableMutationObserver = new MutationObserver((mutations) => {
    const shouldReboot = mutations.some((mutation) => (
      Array.from(mutation.addedNodes).some(nodeContainsCandidateTable) ||
      Array.from(mutation.removedNodes).some(nodeContainsCandidateTable)
    ));

    if (shouldReboot) scheduleBoot();
  });

  tableMutationObserver.observe(document.body, { childList: true, subtree: true });
}

function nodeContainsCandidateTable(node) {
  if (node.nodeType !== Node.ELEMENT_NODE) return false;
  if (node.matches(".sticky-table-header-clone") || node.closest(".sticky-table-header-clone")) return false;

  return node.matches("table, thead, th") || Boolean(node.querySelector("table, thead, th"));
}

function stickyTableCandidates() {
  const candidates = [];
  const seen = new Set();

  document.querySelectorAll(`${MANUAL_TABLE_SELECTOR}, ${AUTO_TABLE_SELECTOR}`).forEach((table) => {
    if (seen.has(table) || !shouldEnhanceTable(table)) return;
    seen.add(table);
    candidates.push(table);
  });

  return candidates;
}

function shouldEnhanceTable(table) {
  if (table.getAttribute("data-sticky-table-header") === "false") return false;
  if (table.closest(SKIP_CONTAINER_SELECTOR)) return false;
  if (table.closest(".sticky-table-header-clone")) return false;
  if (table.closest("template")) return false;
  if (table.getAttribute("role")?.toLowerCase() === "presentation") return false;
  if (!table.tHead || !table.tHead.querySelector("th")) return false;

  return true;
}

document.addEventListener("turbo:load", bootStickyTables);
document.addEventListener("DOMContentLoaded", bootStickyTables);
document.addEventListener("turbo:before-cache", () => {
  if (navResizeObserver) navResizeObserver.disconnect();
  if (tableMutationObserver) tableMutationObserver.disconnect();
  navResizeObserver = null;
  tableMutationObserver = null;
  stickyTables.forEach((stickyTable) => stickyTable.destroy());
  stickyTables = [];
});
window.addEventListener("scroll", scheduleUpdate, { passive: true });
window.addEventListener("resize", scheduleUpdate, { passive: true });
