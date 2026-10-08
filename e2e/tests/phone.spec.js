// The editor on a phone-sized screen, with touch.
const { test, expect } = require('@playwright/test');
const { boxOf, centre, openEditor, cuts } = require('./editor');

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

test('panels are tabs, and a tapped cut opens its settings', async ({
  page,
}) => {
  await openEditor(page);
  await boxOf(page, /^Settings/);
  const card = centre(await boxOf(page, /^Kill at 00:30, /));
  await page.touchscreen.tap(card.x, card.y);
  await expect.poll(() => cuts(page)).toHaveLength(1);

  // back to nothing selected, then the cut itself on the ruler
  const b = centre(await boxOf(page, /^Kill, layer 1, /));
  await page.touchscreen.tap(b.x, b.y);
  await boxOf(page, /(^|\n)Kill at 00:30(\n|$)/); // the selected cut's panel title
});
