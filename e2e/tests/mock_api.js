// The gateway, answered inside the browser: one finished match, and the
// montages it saves kept in memory so a test can read what the editor sent.
//
// Only what the editor asks for on the way is answered; anything else is a
// 404, which the editor already has to survive (a missing frame, a video
// that is not there).

const JOB_ID = 'e2e0000000000001';

const events = [
  { kind: 'kill', t: 30.0 },
  { kind: 'kill', t: 95.0 },
  { kind: 'headshot', t: 140.0 },
  { kind: 'sleep', t: 200.0 },
  { kind: 'kill', t: 260.0 },
  { kind: 'ability_kill', t: 330.0 },
].map((e) => ({ ...e, confidence: 1.0, meta: {} }));

function jobSummary() {
  return {
    id: JOB_ID,
    status: 'ready',
    stage: '',
    n_moments: events.length,
    progress: 1.0,
    error: null,
    video_name: 'Sigma Overwatch 2 Gameplay.mp4',
    duration_s: 733.0,
    fps: 4.0,
    width: 480,
    height: 270,
    params: {},
    created_at: '2026-10-08T21:36:20+00:00',
    updated_at: '2026-10-08T21:36:20+00:00',
    n_renders: 0,
    has_active_render: false,
    n_clips: 0,
    video_url: `/api/jobs/${JOB_ID}/video`,
    proxy_url: null,
    zip_url: null,
    has_cuts: false,
    clips_only_cuts: 0,
  };
}

/** Installs the fake API on [page]; returns what the editor saved. */
async function mockApi(page) {
  const state = { montages: [], draft: null, saves: [] };
  let next = 1;

  const job = () => ({
    ...jobSummary(),
    renders: [],
    events,
    detectors: [],
    clips: [],
    media: [],
    tracks: [],
    montages: state.montages,
    draft: state.draft,
    waveform: [],
  });

  const montage = (name, data) => {
    const now = new Date().toISOString();
    return {
      id: `m${next++}`,
      job_id: JOB_ID,
      name: name || 'My montage',
      created_at: now,
      updated_at: now,
      n_versions: 0,
      n_clips: 0,
      duration_s: 0,
      has_music: false,
      data: data || { title: name || 'My montage', layers: [] },
    };
  };

  await page.route('**/api/**', async (route) => {
    const req = route.request();
    const { pathname } = new URL(req.url());
    const method = req.method();
    const json = (body, status = 200) =>
      route.fulfill({
        status,
        contentType: 'application/json',
        body: JSON.stringify(body),
      });
    const body = () => {
      try {
        return req.postDataJSON() || {};
      } catch {
        return {};
      }
    };

    if (pathname === '/api/jobs') return json({ jobs: [jobSummary()] });
    if (pathname === `/api/jobs/${JOB_ID}`) return json(job());
    if (pathname === `/api/jobs/${JOB_ID}/frames`) return json({}, 202);
    if (pathname === `/api/jobs/${JOB_ID}/draft`) {
      if (method === 'PUT') state.draft = body();
      return method === 'DELETE' ? route.fulfill({ status: 204 }) : json({});
    }
    if (pathname === `/api/jobs/${JOB_ID}/montages`) {
      if (method === 'POST') {
        const b = body();
        const m = montage(b.name, b.data);
        state.montages.push(m);
        if (b.data) state.saves.push(b.data);
        return json(m);
      }
      return json({ job_id: JOB_ID, items: state.montages });
    }
    const one = pathname.match(/^\/api\/jobs\/[^/]+\/montages\/([^/]+)$/);
    if (one) {
      const m = state.montages.find((x) => x.id === one[1]);
      if (!m) return json({ detail: 'no such montage' }, 404);
      if (method === 'PUT') {
        const b = body();
        if (b.data) {
          m.data = b.data;
          state.saves.push(b.data);
        }
        if (b.name) m.name = b.name;
        return json(m);
      }
      if (method === 'DELETE') return route.fulfill({ status: 204 });
      return json(m);
    }
    if (pathname.endsWith('/versions')) return json({ items: [] });
    if (pathname === '/api/presets') return json({ items: [] });
    if (pathname === '/api/renders') return json({ renders: [] });
    if (pathname === '/api/sfx') return json({ categories: [], effects: [] });
    if (pathname === '/api/stickers') {
      return json({ categories: [], colors: [], stickers: [] });
    }
    if (pathname === '/api/fonts') return json([]);
    return route.fulfill({ status: 404, body: 'not in the e2e fake' });
  });

  return state;
}

module.exports = { mockApi, JOB_ID };
