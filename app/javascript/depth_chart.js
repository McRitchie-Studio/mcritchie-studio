// DepthChart — client helpers for the studio/board depth chart (studio-engine 0.29.0).
//
// The window.studioBoard factory now owns drag + within-lane reorder (it POSTs the
// lane's DOM-ordered entry_ids to Studio::Board::Reorderable, which restamps depths
// 1..N skipping locked entries). This module keeps only the two depth-chart-specific
// bits the neutral factory does NOT own:
//
//   depthChartRenumber({ ids, zone })  — the board's on_drop_hook. After a reorder it
//     restamps the VISIBLE depth column (the data-depth span) for that lane 1..N by DOM
//     order. Because a locked card can't be dragged and no card may cross it (the
//     factory's lockedSelector pin guard), a pinned card's DOM index never moves, so
//     idx+1 stays consistent with the server's skip-locked depth.
//
//   depthChartLock.toggle(id, btn)     — the per-card lock button. POSTs toggle_lock,
//     then flips .kanban-locked (which the factory filters from dragging) + the 🔒/🔓
//     glyph on the card.

window.depthChartRenumber = function (detail) {
  var zone = document.getElementById("dropzone-" + (detail && detail.zone));
  if (!zone) return;
  var cards = zone.querySelectorAll(".kanban-card");
  for (var i = 0; i < cards.length; i++) {
    var span = cards[i].querySelector("[data-depth]");
    if (span) span.textContent = i + 1;
  }
};

window.depthChartLock = {
  csrf: function () {
    return (document.querySelector('meta[name="csrf-token"]') || {}).content;
  },

  toggle: function (id, btn) {
    var self = this;
    fetch("/depth_chart_entries/" + id + "/toggle_lock", {
      method: "POST",
      headers: { "X-CSRF-Token": self.csrf(), "Accept": "application/json" }
    }).then(function (resp) {
      if (!resp.ok) throw new Error("lock failed");
      return resp.json();
    }).then(function (data) {
      var card = btn.closest(".kanban-card");
      if (card) {
        card.classList.toggle("kanban-locked", data.locked);
        card.dataset.locked = data.locked;
      }
      var span = btn.querySelector("[data-label]");
      if (span) span.textContent = data.locked ? "🔒" : "🔓";
      btn.title = data.locked ? "Unlock" : "Lock";
    }).catch(function (e) {
      console.error(e);
      alert("Lock toggle failed.");
    });
  }
};
