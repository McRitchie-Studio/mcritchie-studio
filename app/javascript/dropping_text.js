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
//   data-fit-width    — if present, the box narrows/widens to each word as it
//                       enters (a word mid-line, so a short one leaves no gap)

var _droppingTimers = [];

function initDroppingTexts() {
  document.querySelectorAll('.dropping-texts').forEach(container => {
    if (container.dataset.initialized) return;
    container.dataset.initialized = 'true';

    const spans = Array.from(container.querySelectorAll(':scope > span'));
    if (spans.length === 0) return;

    const stopOnLast = container.hasAttribute('data-stop-on-last');
    const interval = parseInt(container.dataset.interval) || 2500;
    const fitWidth = container.hasAttribute('data-fit-width');
    let current = 0;

    // The text's own width, whatever the span's box is stretched to.
    const textWidth = (span) => {
      const range = document.createRange();
      range.selectNodeContents(span);
      return Math.ceil(range.getBoundingClientRect().width);
    };
    const setWidth = (px) => { container.style.width = `${px}px`; };
    const fit = () => { if (fitWidth) setWidth(textWidth(spans[current])); };

    // Show first word immediately
    spans[current].classList.add('drop-active');
    fit();
    if (fitWidth) {
      container._dropFit = fit;
      window.addEventListener('resize', fit);
      // The first measure can read the fallback font on a cold load.
      document.fonts?.ready.then(fit);
    }

    const timer = setInterval(() => {
      // Reset previously exited spans
      spans.forEach((s, i) => {
        if (i !== current) s.classList.remove('drop-exit');
      });

      // Exit current word
      spans[current].classList.remove('drop-active');
      spans[current].classList.add('drop-exit');

      // Advance
      const leaving = spans[current];
      current = stopOnLast ? current + 1 : (current + 1) % spans.length;

      // Grow early, shrink late: the box widens for a longer word while the
      // old one drops out (the 0.4s width ease fits inside the 400ms gap), so
      // the new word never enters a box narrower than itself; a shorter word
      // enters the wide box and the box closes on it once it is in.
      if (fitWidth) setWidth(Math.max(textWidth(leaving), textWidth(spans[current])));

      // Enter next word after exit transition clears
      setTimeout(() => {
        spans[current].classList.add('drop-active');
        fit();
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
    if (container._dropFit) {
      window.removeEventListener('resize', container._dropFit);
      delete container._dropFit;
      container.style.width = '';
    }
    container.querySelectorAll(':scope > span').forEach(s => {
      s.classList.remove('drop-active', 'drop-exit');
    });
  });
}

document.addEventListener('turbo:load', initDroppingTexts);
document.addEventListener('turbo:before-cache', cleanupDroppingTexts);
