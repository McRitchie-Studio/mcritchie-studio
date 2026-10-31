// Dropping text animation — cycles child spans with drop-in/drop-out transitions.
//
// Usage:
//   <span class="dropping-texts" data-spacer="LongestWord">
//     <span>Word1</span>
//     <span>Word2</span>
//   </span>
//
// Data attributes:
//   data-spacer       — invisible text to set container width (use longest word)
//   data-stop-on-last — if present, stops on the final word
//   data-interval     — ms between words (default: 2500)

var _droppingTimers = [];

function initDroppingTexts() {
  document.querySelectorAll('.dropping-texts').forEach(container => {
    if (container.dataset.initialized) return;
    container.dataset.initialized = 'true';

    const spans = Array.from(container.querySelectorAll(':scope > span'));
    if (spans.length === 0) return;

    const stopOnLast = container.hasAttribute('data-stop-on-last');
    const interval = parseInt(container.dataset.interval) || 2500;
    let current = 0;

    // Show first word immediately
    spans[current].classList.add('drop-active');

    const timer = setInterval(() => {
      // Reset previously exited spans
      spans.forEach((s, i) => {
        if (i !== current) s.classList.remove('drop-exit');
      });

      // Exit current word
      spans[current].classList.remove('drop-active');
      spans[current].classList.add('drop-exit');

      // Advance
      current = stopOnLast ? current + 1 : (current + 1) % spans.length;

      // Enter next word after exit transition clears
      setTimeout(() => {
        spans[current].classList.add('drop-active');
      }, 400);

      // Stop on last if configured
      if (stopOnLast && current >= spans.length - 1) {
        clearInterval(timer);
      }
    }, interval);

    _droppingTimers.push(timer);
  });
}

function cleanupDroppingTexts() {
  _droppingTimers.forEach(t => clearInterval(t));
  _droppingTimers = [];
  document.querySelectorAll('.dropping-texts').forEach(container => {
    delete container.dataset.initialized;
    container.querySelectorAll(':scope > span').forEach(s => {
      s.classList.remove('drop-active', 'drop-exit');
    });
  });
}

document.addEventListener('turbo:load', initDroppingTexts);
document.addEventListener('turbo:before-cache', cleanupDroppingTexts);
