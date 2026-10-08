// Finding things in a Flutter page. It is one canvas: what a test can name
// is the semantics tree (the same labels a screen reader hears), so it is
// turned on first and every lookup goes through it.
const { expect } = require('@playwright/test');
const { mockApi } = require('./mock_api');

/** The label of each semantics node and where it is on the page. */
async function nodes(page) {
  return page.$$eval('flt-semantics', (els) =>
    els.map((e) => {
      const own = e.querySelector('flt-semantics') ? '' : e.textContent;
      const r = e.getBoundingClientRect();
      return {
        label: (e.getAttribute('aria-label') || own || '').trim(),
        box: { x: r.x, y: r.y, width: r.width, height: r.height },
      };
    }),
  );
}

/** Every label on the page matching [re]. */
async function labels(page, re) {
  return (await nodes(page)).map((n) => n.label).filter((l) => re.test(l));
}

/** The box of the one node whose label matches [re], waiting for it. */
async function boxOf(page, re) {
  let found;
  await expect
    .poll(
      async () => {
        found = (await nodes(page)).filter((n) => re.test(n.label));
        return found.length;
      },
      { message: `a node labelled ${re}` },
    )
    .toBeGreaterThan(0);
  return found[0].box;
}

const centre = (b) => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 });

async function click(page, re) {
  const c = centre(await boxOf(page, re));
  await page.mouse.click(c.x, c.y);
}

/** A real drag: press, move in steps (Flutter needs the moves to see a
 * drag, not a tap), let go. */
async function drag(page, from, to, { steps = 20 } = {}) {
  await page.mouse.move(from.x, from.y);
  await page.mouse.down();
  await page.mouse.move(from.x + 4, from.y + 2, { steps: 2 });
  await page.mouse.move(to.x, to.y, { steps });
  await page.mouse.up();
}

/** The fake API, the app, the semantics tree, and the editor of the match
 * open. Returns what the editor saves. */
async function openEditor(page) {
  const saved = await mockApi(page);
  page.on('pageerror', (e) => {
    throw e;
  });
  await page.goto('/');
  // Flutter keeps the tree off until a screen reader asks for it; this
  // hidden button is how one asks
  await page.waitForSelector('flt-semantics-placeholder', { state: 'attached' });
  await page.evaluate(() =>
    document.querySelector('flt-semantics-placeholder').click(),
  );
  await click(page, /Sigma Overwatch 2 Gameplay/);
  await click(page, /^(Open the editor|Keep editing)$/);
  await boxOf(page, /^Timeline: /);
  return saved;
}

/** The cuts on the ruler, by their sentence. */
const cuts = (page) => labels(page, /, layer [^,]+, from \d\d:\d\d to /);

module.exports = { nodes, labels, boxOf, centre, click, drag, openEditor, cuts };
