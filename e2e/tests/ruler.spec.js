// The ruler with a real mouse in Chromium: the gestures widget tests only
// simulate. Each test starts from an empty montage of the fake match.
const { test, expect } = require('@playwright/test');
const {
  boxOf,
  centre,
  click,
  drag,
  openEditor,
  cuts,
  labels,
} = require('./editor');

const kill = /^Kill at 00:30, /;
const ruler = /^Timeline: /;

/** A point on the first track, [s] seconds in (at the default zoom). */
async function onTrack(page, s) {
  const header = await boxOf(page, /(^|\n)Layer 1$/);
  return {
    x: header.x + header.width + 1 + s * 60,
    y: header.y + header.height / 2,
  };
}

/** Seconds from a cut's sentence: "…, from 00:02 to 00:03, 1.2 seconds". */
const seconds = (label) => Number(label.match(/([\d.]+) seconds/)[1]);
const from = (label) => label.match(/from (\d\d:\d\d)/)[1];

test('a moment dragged onto the ruler becomes a cut, and is saved', async ({
  page,
}) => {
  const saved = await openEditor(page);
  await drag(page, centre(await boxOf(page, kill)), await onTrack(page, 2));

  await expect.poll(() => cuts(page)).toHaveLength(1);
  const [cut] = await cuts(page);
  expect(cut).toMatch(/^Kill, layer 1, from 00:0[12] /);
  await expect
    .poll(() => labels(page, kill))
    .toEqual([expect.stringMatching(/already in the montage$/)]);
  // the editor saves on its own, a moment later
  await expect
    .poll(() => saved.saves.at(-1)?.layers?.[0]?.clips?.length ?? 0, {
      timeout: 15_000,
    })
    .toBe(1);
});

test('a cut dragged sideways moves in time; Ctrl+Z puts it back', async ({
  page,
}) => {
  await openEditor(page);
  await drag(page, centre(await boxOf(page, kill)), await onTrack(page, 0));
  await expect.poll(() => cuts(page)).toHaveLength(1);
  expect(from((await cuts(page))[0])).toBe('00:00');

  const block = centre(await boxOf(page, /^Kill, layer 1, /));
  await drag(page, block, { x: block.x + 4 * 60, y: block.y });
  await expect.poll(async () => from((await cuts(page))[0])).toBe('00:04');

  await page.keyboard.press('Control+z');
  await expect.poll(async () => from((await cuts(page))[0])).toBe('00:00');
});

test('the left handle of a chosen cut trims it', async ({ page }) => {
  await openEditor(page);
  await click(page, kill);
  await expect.poll(() => cuts(page)).toHaveLength(1);
  const before = seconds((await cuts(page))[0]);

  // chosen, it shows its handles: the left one is the first 26px
  const b = await boxOf(page, /^Kill, layer 1, /);
  await page.mouse.click(b.x + b.width / 2, b.y + b.height / 2);
  const grip = { x: b.x + 8, y: b.y + b.height / 2 };
  await drag(page, grip, { x: grip.x + 24, y: grip.y });

  await expect
    .poll(async () => seconds((await cuts(page))[0]))
    .toBeLessThan(before);
});

test('a cut dragged down goes to the layer below', async ({ page }) => {
  await openEditor(page);
  await click(page, kill);
  await click(page, /^New layer$/);
  await boxOf(page, /(^|\n)Layer 2$/);
  await expect.poll(() => cuts(page)).toHaveLength(1);
  // which layer holds it depends on the active one: take it to the other
  const startLayer = (await cuts(page))[0].match(/layer (\d)/)[1];
  const other = startLayer === '1' ? '2' : '1';
  const b = centre(await boxOf(page, /^Kill, layer \d, /));
  const here = centre(await boxOf(page, new RegExp(`(^|\\n)Layer ${startLayer}$`)));
  const there = centre(await boxOf(page, new RegExp(`(^|\\n)Layer ${other}$`)));
  await drag(page, b, { x: b.x, y: b.y + there.y - here.y });

  await expect
    .poll(async () => (await cuts(page))[0])
    .toMatch(new RegExp(`^Kill, layer ${other}, `));
});

test('Alt+arrows walk the cuts from the keyboard', async ({ page }) => {
  await openEditor(page);
  await click(page, kill);
  await click(page, /^Headshot at 02:20, /);
  await expect.poll(() => cuts(page)).toHaveLength(2);
  await page.keyboard.press('Escape');
  // a click on the ruler (as before using its keys), then, from wherever
  // the playhead is, back to the first cut
  await click(page, ruler);
  await page.keyboard.press('Alt+ArrowLeft');
  await page.keyboard.press('Alt+ArrowLeft');
  await page.keyboard.press('Alt+ArrowLeft');
  await expect
    .poll(async () => (await cuts(page)).filter((c) => c.endsWith('selected')))
    .toEqual([expect.stringMatching(/^Kill, layer 1, from 00:00 /)]);

  await page.keyboard.press('Alt+ArrowRight');
  await expect
    .poll(async () => (await cuts(page)).filter((c) => c.endsWith('selected')))
    .toEqual([expect.stringMatching(/^Headshot, layer 1, /)]);
});
