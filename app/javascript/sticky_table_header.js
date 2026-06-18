const TABLE_SELECTOR = "[data-sticky-table-header]";

let stickyTables = [];
let scheduled = false;
let navResizeObserver = null;

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

class StickyTableHeader {
  constructor(table) {
    this.table = table;
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
  if (navResizeObserver) navResizeObserver.disconnect();
  if (window.ResizeObserver) {
    const header = document.querySelector("header");
    if (header) {
      navResizeObserver = new ResizeObserver(scheduleUpdate);
      navResizeObserver.observe(header);
    }
  }

  stickyTables.forEach((stickyTable) => stickyTable.destroy());
  stickyTables = Array.from(document.querySelectorAll(TABLE_SELECTOR)).map((table) => new StickyTableHeader(table));
  scheduleUpdate();
}

document.addEventListener("turbo:load", bootStickyTables);
document.addEventListener("DOMContentLoaded", bootStickyTables);
document.addEventListener("turbo:before-cache", () => {
  if (navResizeObserver) navResizeObserver.disconnect();
  navResizeObserver = null;
  stickyTables.forEach((stickyTable) => stickyTable.destroy());
  stickyTables = [];
});
window.addEventListener("scroll", scheduleUpdate, { passive: true });
window.addEventListener("resize", scheduleUpdate, { passive: true });
