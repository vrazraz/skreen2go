// Recreate Windows frames from the macOS Rive source. Run `npm install && npm run export`.
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile, access } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const source = join(root, 'Sources/Skreen2GoCore/Resources/hand.riv');
const output = join(root, 'Windows/Skreen2Go.Windows/Resources/HandFrames');
const files = new Map([
  ['/rive.js', join(here, 'node_modules/@rive-app/canvas/rive.js')],
  ['/rive.wasm', join(here, 'node_modules/@rive-app/canvas/rive.wasm')],
  ['/hand.riv', source],
]);
const html = `<!doctype html><canvas id="art" width="900" height="585"></canvas>
<script src="/rive.js"></script><script>
rive.RuntimeLoader.setWasmUrl('/rive.wasm');
window.player = new rive.Rive({
  src: '/hand.riv', canvas: document.getElementById('art'),
  animations: 'Timeline 1', autoplay: true,
  onLoad: () => { window.ready = true; },
  onLoadError: error => { window.error = String(error); }
});
</script>`;
const server = createServer(async (request, response) => {
  try {
    if (request.url === '/') {
      response.writeHead(200, { 'Content-Type': 'text/html' });
      response.end(html);
      return;
    }
    const path = files.get(request.url);
    if (!path) { response.writeHead(404); response.end(); return; }
    response.writeHead(200, { 'Content-Type': path.endsWith('.wasm')
      ? 'application/wasm' : 'application/octet-stream' });
    response.end(await readFile(path));
  } catch (error) { response.writeHead(500); response.end(String(error)); }
});

await new Promise(done => server.listen(0, '127.0.0.1', done));
const defaultChrome = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const chrome = process.env.CHROME_PATH ??
  (await access(defaultChrome).then(() => defaultChrome, () => undefined));
const browser = await chromium.launch({ headless: true,
  ...(chrome ? { executablePath: chrome } : {}) });
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 585 },
    deviceScaleFactor: 1 });
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.waitForFunction(() => window.ready || window.error);
  const error = await page.evaluate(() => window.error);
  if (error) throw new Error(error);
  await page.evaluate(() => window.player.pause());
  await page.waitForTimeout(260);
  await mkdir(output, { recursive: true });
  // The source animation is 85 frames at 60fps. HandFlourish.swift plays it at 1.75x.
  const authoredDuration = 85 / 60;
  const playbackSpeed = 1.75;
  const count = Math.ceil(authoredDuration / playbackSpeed * 60);
  for (let index = 0; index < count; index++) {
    const time = Math.min(authoredDuration - .0001, index * playbackSpeed / 60);
    const uri = await page.evaluate(async position => {
      window.player.scrub('Timeline 1', position);
      await new Promise(requestAnimationFrame);
      return document.getElementById('art').toDataURL('image/png');
    }, time);
    await writeFile(join(output, `${String(index).padStart(3, '0')}.png`),
      Buffer.from(uri.split(',')[1], 'base64'));
  }
  process.stdout.write(`Exported ${count} original Rive frames to ${output}\n`);
} finally {
  await browser.close();
  await new Promise(done => server.close(done));
}
