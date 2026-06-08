const { chromium } = require('playwright');
const path = require('path');
const H = 'http://127.0.0.1:3030/email';

const html = `<!doctype html><html><head><meta charset="utf-8">
<style>
  *{margin:0;padding:0;box-sizing:border-box;}
  body{background:#fff;}
  .hero{position:relative;width:600px;height:232px;overflow:hidden;
        font-family:'Segoe UI',Helvetica,Arial,sans-serif;
        background:linear-gradient(180deg,#8E82FE 0%,#8E82FE 9%,#3a3470 28%,#0b1220 48%);}
  .ph{position:absolute;top:0;left:0;width:600px;height:232px;
       background-repeat:no-repeat;background-size:auto 100%;}
  .left{clip-path:polygon(0 0, 58.5% 0, 41.5% 100%, 0 100%);background-position:left center;}
  .right{clip-path:polygon(60.7% 0, 100% 0, 100% 100%, 43.7% 100%);background-position:right center;}
  .overlay{position:absolute;inset:0;
           background:linear-gradient(180deg,rgba(11,18,32,0) 0%,rgba(11,18,32,0.03) 34%,rgba(11,18,32,0.30) 100%);}
  /* --- FADING GLOW (commented out — may revisit) ---
  .glow{position:absolute;left:50%;top:-54px;transform:translateX(-50%);
        width:320px;height:122px;border-radius:46px;pointer-events:none;
        background:radial-gradient(64% 70% at 50% 50%,
                   #4f43c6 0%, #6a5ee6 38%, #8E82FE 74%, #9a8ffe 100%);
        filter:blur(26px);}
  --- end fading glow --- */

  /* structured, slightly transparent brand bar (centered rectangle) */
  .plate{position:absolute;top:0;left:50%;transform:translateX(-50%);
         display:flex;align-items:center;gap:12px;
         height:62px;padding:0 22px;
         border-radius:0 0 20px 20px;
         background:linear-gradient(180deg, rgba(101,89,222,0.66) 0%, rgba(79,67,198,0.56) 100%);}
  .plate img{width:30px;height:30px;display:block;}
  .plate span{color:#fff;font-size:18px;font-weight:700;letter-spacing:0.4px;white-space:nowrap;}
  .plate b{font-weight:400;color:#ede9ff;}
</style></head>
<body>
  <div class="hero">
    <div class="ph left"  style="background-image:url(${H}/pulisic.jpg)"></div>
    <div class="ph right" style="background-image:url(${H}/ronaldo.jpg)"></div>
    <div class="overlay"></div>
    <!-- <div class="glow"></div>  fading shape — commented out, may revisit -->
    <!-- brand moved to a solid purple band in the layout (no longer overlaid on photos)
    <div class="plate">
      <img src="${H}/studio-logo-white.png">
      <span>McRitchie&nbsp;<b>Studio</b></span>
    </div>
    -->
  </div>
</body></html>`;

(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 600, height: 232 }, deviceScaleFactor: 2 });
  await p.setContent(html, { waitUntil: 'networkidle' });
  await p.locator('.hero').screenshot({ path: path.resolve(__dirname, '..', '..', 'public', 'email', 'world_cup_header.png') });
  await b.close();
  console.log('wrote public/email/world_cup_header.png');
})();
