/* lockfreequeues bench charts — uPlot wiring for docs/benchmarks.md.
 *
 * Loads the merged Bencher Metric Format (BMF) snapshot from
 * `../assets/bench-results/latest.json` — page lives at
 * `/<version>/benchmarks/` under mike + mkdocs `use_directory_urls`,
 * so we go up one level to reach `/<version>/assets/`. The same
 * relative path works under /dev/, /latest/, and /v*\/ aliases.
 *
 * Page architecture (multi-panel):
 *   #bench-hero                       — hand-rendered DOM bar chart at
 *                                       a canonical shape (lfq vs alts)
 *   #bench-throughput-spsc            — uPlot line chart, SPSC topology
 *   #bench-throughput-mpsc            — uPlot line chart, MPSC topology
 *   #bench-throughput-mpmc-bounded    — uPlot line chart, MPMC bounded
 *   #bench-throughput-mpmc-unbounded  — uPlot line chart, MPMC unbounded
 *   #bench-latency                    — placeholder (filled by A2)
 *   #bench-status                     — banner injected on fallback/fixture
 *
 * Slug shape: `<library>/<topology>/<P>p<C>c`
 *   library  = everything up to the first '/'
 *   topology = e.g. spsc, mpmc, mpsc, mpmc_unbounded, spsc_unbounded
 *   shape    = `<P>p<C>c` where P,C are non-negative ints
 *
 * BMF measure shape: `{ value: number, lower_value?: number, upper_value?: number }`.
 * `lower_value` / `upper_value` are mean ± stddev when present (throughput);
 * latency percentile measures emit `value` only.
 *
 * Failure modes (graceful):
 *   - latest.json fetch fails or returns _status: "fallback" -> try
 *     example.json fixture and surface a status banner.
 *   - fixture also unavailable -> error banner; panels show empty state.
 *   - uPlot global missing -> per-panel message; hero still renders.
 */

(function () {
  'use strict';

  // ── module: constants ───────────────────────────────────────────────
  const SNAPSHOT_URL  = '../assets/bench-results/latest.json';
  const FIXTURE_URL   = '../assets/bench-results/example.json';
  const CHART_MEASURE = 'throughput_ops_ms';

  // CONTRACT-TEST-PARSED-START LIBRARY_COLORS
  const LIBRARY_COLORS = Object.freeze({
    // lockfreequeues family (bounded) — Material indigo 500
    lockfreequeues_sipsic:           '#3f51b5',
    lockfreequeues_sipmuc:           '#3f51b5',
    lockfreequeues_mupsic:           '#3f51b5',
    lockfreequeues_mupmuc:           '#3f51b5',
    // lockfreequeues family (unbounded) — Material indigo 400
    lockfreequeues_unbounded_sipsic: '#5c6bc0',
    lockfreequeues_unbounded_sipmuc: '#5c6bc0',
    lockfreequeues_unbounded_mupsic: '#5c6bc0',
    lockfreequeues_unbounded_mupmuc: '#5c6bc0',
    // comparison libraries — distinct stable colors
    crossbeam_array_queue:           '#f4511e',
    crossbeam_seg_queue:             '#fb8c00',
    moodycamel:                      '#43a047',
    boost_lockfree_queue:            '#00897b',
    boost_lockfree_spsc:             '#00897b',
    loony:                           '#8e24aa',
    threading_channels:              '#6d4c41',
    nim_channel:                     '#546e7a',
  });
  // CONTRACT-TEST-PARSED-END LIBRARY_COLORS

  // CONTRACT-TEST-PARSED-START BLOCKING_LIBRARIES
  const BLOCKING_LIBRARIES = ['threading_channels', 'nim_channel'];
  // CONTRACT-TEST-PARSED-END BLOCKING_LIBRARIES
  const BLOCKING_SET = new Set(BLOCKING_LIBRARIES);

  const LOCKFREEQUEUES_FAMILY = [
    'lockfreequeues_sipsic', 'lockfreequeues_sipmuc',
    'lockfreequeues_mupsic', 'lockfreequeues_mupmuc',
    'lockfreequeues_unbounded_sipsic', 'lockfreequeues_unbounded_sipmuc',
    'lockfreequeues_unbounded_mupsic', 'lockfreequeues_unbounded_mupmuc',
  ];
  const LFQ_FAMILY_SET = new Set(LOCKFREEQUEUES_FAMILY);

  const HERO_SHAPE_PREFERENCE = [
    { topology: 'mpmc',           shape: '4p4c' },
    { topology: 'mpmc',           shape: '2p2c' },
    { topology: 'mpsc',           shape: '4p1c' },
    { topology: 'spsc',           shape: '1p1c' },
  ];

  // Map a topology slug substring to its DOM panel id.
  // Topologies in BMF: spsc, mpsc, mpmc, mpmc_unbounded, spsc_unbounded.
  // Bounded + unbounded variants share a panel for each core topology
  // (SPSC, MPSC) so unbounded data renders alongside its bounded peer.
  // MPMC keeps two panels (bounded vs unbounded) because the MPMC
  // bounded panel is already crowded with comparison libraries; mixing
  // unbounded in there would muddle the comparison.
  // Library color discipline (LIBRARY_COLORS) gives lockfreequeues
  // bounded #3f51b5 and unbounded #5c6bc0, so co-located series stay
  // visually distinguishable.
  const THROUGHPUT_PANELS = [
    { id: 'bench-throughput-spsc',           label: 'SPSC',
      includes: (topology) => topology === 'spsc'
                              || topology === 'spsc_unbounded' },
    { id: 'bench-throughput-mpsc',           label: 'MPSC',
      includes: (topology) => topology === 'mpsc'
                              || topology === 'mpsc_unbounded' },
    { id: 'bench-throughput-mpmc-bounded',   label: 'MPMC (bounded)',
      includes: (topology) => topology === 'mpmc' },
    { id: 'bench-throughput-mpmc-unbounded', label: 'MPMC (unbounded)',
      includes: (topology) => topology === 'mpmc_unbounded' },
  ];

  // Index-based fallback palette for libraries not in LIBRARY_COLORS.
  // Picked to be distinguishable on the slate-dark Material theme.
  const FALLBACK_PALETTE = [
    '#7eb6ff', '#ff9f7e', '#9ee37e', '#d77eff', '#ffeb7e',
    '#7effd9', '#ff7e9c', '#bfff7e', '#7e9cff', '#ffb87e',
  ];
  let _fallbackIdx = 0;
  const _fallbackAssigned = new Map();

  function getColor(library) {
    if (LIBRARY_COLORS[library]) return LIBRARY_COLORS[library];
    if (_fallbackAssigned.has(library)) return _fallbackAssigned.get(library);
    // First time seeing this library: warn once and assign a stable color.
    console.warn(
      "[bench-charts] library '" + library +
      "' has no entry in LIBRARY_COLORS; falling back to palette[" +
      (_fallbackIdx % FALLBACK_PALETTE.length) +
      "]. Add it to LIBRARY_COLORS in docs/assets/bench-charts.js."
    );
    const c = FALLBACK_PALETTE[_fallbackIdx % FALLBACK_PALETTE.length];
    _fallbackIdx += 1;
    _fallbackAssigned.set(library, c);
    return c;
  }

  function isBlocking(library) { return BLOCKING_SET.has(library); }
  function isLockfreequeues(library) {
    return LFQ_FAMILY_SET.has(library) || library.startsWith('lockfreequeues_');
  }
  function displayLabel(library) {
    return library + (isBlocking(library) ? ' *' : '');
  }

  // ── module: helpers ─────────────────────────────────────────────────

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const k in attrs) {
        if (k === 'class') node.className = attrs[k];
        else if (k === 'style') node.setAttribute('style', attrs[k]);
        else node.setAttribute(k, attrs[k]);
      }
    }
    for (const c of children) {
      if (c == null) continue;
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return node;
  }

  function parseSlug(slug) {
    // `<library>/<topology>/<P>p<C>c` — first segment library, last shape.
    // Topology may include internal slashes; we join all middle segments.
    const parts = slug.split('/');
    if (parts.length < 3) return null;
    const library = parts[0];
    const topology = parts.slice(1, -1).join('/');
    const shape = parts[parts.length - 1];
    const m = /^(\d+)p(\d+)c$/.exec(shape);
    if (!m) return null;
    const p = parseInt(m[1], 10);
    const c = parseInt(m[2], 10);
    return { library, topology, shape, p, c, totalThreads: p + c };
  }

  // Sort shape labels by total thread count, then by P, then by C.
  function sortShapeLabels(labels) {
    return Array.from(labels)
      .map((label) => {
        const m = /^(\d+)p(\d+)c$/.exec(label);
        if (!m) return { label, p: -1, c: -1, total: -1 };
        const p = parseInt(m[1], 10);
        const c = parseInt(m[2], 10);
        return { label, p, c, total: p + c };
      })
      .sort((a, b) => {
        if (a.total === -1 && b.total === -1) return a.label.localeCompare(b.label);
        if (a.total === -1) return -1;
        if (b.total === -1) return 1;
        return (a.total - b.total) || (a.p - b.p) || (a.c - b.c);
      })
      .map((item) => item.label);
  }

  // ── module: data ────────────────────────────────────────────────────

  /* Build a nested grouping for downstream rendering:
   *   byTopology: Map<topology, Map<library, Map<shape, MeasureValue>>>
   *
   * Reserved keys (`_status`, `_reason`, `_merge_outcome`, anything
   * leading with `_`) are ignored so fallback metadata doesn't leak
   * into the grouping.
   */
  function groupByTopology(bmf) {
    const byTopology = new Map();
    for (const slug in bmf) {
      if (!Object.prototype.hasOwnProperty.call(bmf, slug)) continue;
      if (slug.startsWith('_')) continue;
      const measureMap = bmf[slug];
      if (!measureMap || typeof measureMap !== 'object') continue;
      const m = measureMap[CHART_MEASURE];
      if (!m || typeof m.value !== 'number' || !Number.isFinite(m.value)) continue;
      const parsed = parseSlug(slug);
      if (!parsed) continue;
      let libsByShape = byTopology.get(parsed.topology);
      if (!libsByShape) {
        libsByShape = new Map();
        byTopology.set(parsed.topology, libsByShape);
      }
      let shapeMap = libsByShape.get(parsed.library);
      if (!shapeMap) {
        shapeMap = new Map();
        libsByShape.set(parsed.library, shapeMap);
      }
      shapeMap.set(parsed.shape, {
        value: m.value,
        lower: typeof m.lower_value === 'number' ? m.lower_value : null,
        upper: typeof m.upper_value === 'number' ? m.upper_value : null,
        slug: slug,
        p: parsed.p,
        c: parsed.c,
      });
    }
    return byTopology;
  }

  // ── module: hero selection ──────────────────────────────────────────

  function pickHeroShape(byTopology) {
    for (const pref of HERO_SHAPE_PREFERENCE) {
      const inTopology = byTopology.get(pref.topology);
      if (!inTopology) continue;
      let hasLfq = false;
      let hasAlt = false;
      for (const [library, shapeMap] of inTopology.entries()) {
        const m = shapeMap.get(pref.shape);
        if (!m || typeof m.value !== 'number') continue;
        if (isLockfreequeues(library)) hasLfq = true;
        else hasAlt = true;
        if (hasLfq && hasAlt) return pref;
      }
    }
    return findFallbackHeroShape(byTopology);
  }

  function findFallbackHeroShape(byTopology) {
    let best = null;
    let bestScore = 0;
    for (const [topology, libsByShape] of byTopology) {
      // Pivot to Map<shape, Map<library, MeasureValue>> for scoring.
      const byShape = new Map();
      for (const [library, shapeMap] of libsByShape) {
        for (const [shape, mv] of shapeMap) {
          if (!mv || typeof mv.value !== 'number') continue;
          if (!byShape.has(shape)) byShape.set(shape, new Map());
          byShape.get(shape).set(library, mv);
        }
      }
      for (const [shape, libs] of byShape) {
        let lfq = 0, alt = 0;
        for (const libName of libs.keys()) {
          if (libName.startsWith('lockfreequeues_')) lfq++;
          else alt++;
        }
        if (lfq >= 1 && alt >= 1) {
          const score = lfq + alt;
          if (score > bestScore) {
            bestScore = score;
            best = { topology, shape };
          }
        }
      }
    }
    return best;
  }

  // ── module: hero panel (hand-rendered) ──────────────────────────────

  function renderHero(host, byTopology) {
    host.innerHTML = '';
    const pick = pickHeroShape(byTopology);
    const heading = el('h3', null,
      'Throughput at a glance');
    host.appendChild(heading);
    if (!pick) {
      host.appendChild(el('p', { class: 'bench-hero-empty' },
        'No comparable cross-library data at any shape — see throughput panels below.'));
      return;
    }
    const inTopology = byTopology.get(pick.topology);
    const rows = [];
    for (const [library, shapeMap] of inTopology.entries()) {
      const mv = shapeMap.get(pick.shape);
      if (!mv || typeof mv.value !== 'number') continue;
      rows.push({ library, value: mv.value, slug: mv.slug });
    }
    if (rows.length === 0) {
      host.appendChild(el('p', { class: 'bench-hero-empty' },
        'No data at the chosen hero shape.'));
      return;
    }
    rows.sort((a, b) => b.value - a.value);
    const max = rows[0].value;

    host.appendChild(el('p', { class: 'bench-hero-shape' },
      pick.topology + ' / ' + pick.shape));

    const list = el('ol', { class: 'bench-hero-bars' });
    let sawBlocking = false;
    for (const r of rows) {
      const pct = max > 0 ? (r.value / max * 100) : 0;
      const blocking = isBlocking(r.library);
      if (blocking) sawBlocking = true;
      const color = getColor(r.library);
      const barClass = 'bench-hero-bar' +
        (blocking ? ' bench-hero-bar-blocking' : '');
      // Blocking bars use border-color instead of background; setting
      // the inline `color` lets `currentColor` pick up the library hue.
      const barStyle = blocking
        ? 'width: ' + pct.toFixed(1) + '%; color: ' + color + ';'
        : 'width: ' + pct.toFixed(1) + '%; background: ' + color + ';';
      const li = el('li', {
        class: 'bench-hero-row',
        'data-library': r.library,
        'data-slug': r.slug,
      },
        el('span', { class: 'bench-hero-label' }, displayLabel(r.library)),
        el('span', { class: barClass, style: barStyle }),
        el('span', { class: 'bench-hero-value' },
          r.value.toFixed(1) + ' ops/ms')
      );
      list.appendChild(li);
    }
    host.appendChild(list);
    if (sawBlocking) {
      host.appendChild(el('p', { class: 'bench-hero-footnote' },
        '* Dotted bars: libraries that block on full; throughput reflects ' +
        'blocking semantics, not the non-blocking try_push path.'));
    }
  }

  // ── module: throughput panels (uPlot) ───────────────────────────────

  function renderError(host, message) {
    host.innerHTML = '';
    host.appendChild(el('div', { class: 'bench-chart-error' }, message));
  }

  function buildLegend(libraries, onToggle) {
    const wrap = el('div', { class: 'bench-chart-legend' });
    libraries.forEach((lib, i) => {
      const id = 'bench-legend-' + lib.panelId + '-' + i;
      const cb = el('input', { type: 'checkbox', id });
      cb.checked = true;
      cb.addEventListener('change', () => onToggle(i, cb.checked));
      const swatch = el('span', {
        class: 'bench-chart-swatch' +
          (isBlocking(lib.library) ? ' bench-chart-swatch-blocking' : ''),
        style: isBlocking(lib.library)
          ? 'color: ' + getColor(lib.library) + ';'
          : 'background: ' + getColor(lib.library) + ';',
      });
      const lbl = el('label', { for: id }, swatch, displayLabel(lib.library));
      wrap.appendChild(el('span', { class: 'bench-legend-item' }, cb, lbl));
    });
    return wrap;
  }

  function buildControls(panelId, initialLogScale, onLogToggle) {
    const wrap = el('div', { class: 'bench-chart-controls' });
    const id = 'bench-log-scale-' + panelId;
    const cb = el('input', { type: 'checkbox', id });
    cb.checked = initialLogScale;
    cb.addEventListener('change', () => onLogToggle(cb.checked));
    const lbl = el('label', { for: id }, 'Log-scale Y axis');
    wrap.appendChild(el('span', { class: 'bench-control-item' }, cb, lbl));
    return wrap;
  }

  function tooltipPlugin(libraries, xLabels) {
    let tip;
    return {
      hooks: {
        init: (u) => {
          tip = el('div', { class: 'bench-chart-tooltip' });
          tip.style.display = 'none';
          u.over.appendChild(tip);
        },
        setCursor: (u) => {
          const { idx, left, top } = u.cursor;
          if (idx == null || left < 0 || top < 0) {
            if (tip) tip.style.display = 'none';
            return;
          }
          const shape = xLabels[idx];
          const lines = [];
          for (let i = 0; i < libraries.length; i++) {
            const s = u.series[i + 1];
            if (!s.show) continue;
            const lib = libraries[i];
            if (!lib._shapeMap) {
              lib._shapeMap = new Map(lib.points.map((p) => [p.shape, p]));
            }
            const point = lib._shapeMap.get(shape);
            if (!point) continue;
            let line = displayLabel(lib.library) + ': ' +
              point.value.toFixed(1) + ' ops/ms';
            if (point.lower != null && point.upper != null) {
              const stddev = (point.upper - point.lower) / 2;
              line += ' (±' + stddev.toFixed(1) + ')';
            }
            lines.push(line);
          }
          if (lines.length === 0) {
            tip.style.display = 'none';
            return;
          }
          tip.innerHTML =
            '<strong>' + shape + '</strong><br>' + lines.join('<br>');
          tip.style.display = 'block';
          tip.style.left = left + 12 + 'px';
          tip.style.top = top + 12 + 'px';
        },
      },
    };
  }

  function makeThroughputOpts(host, libraries, xLabels, logScale) {
    const series = [{ label: 'shape' }].concat(
      libraries.map((lib) => {
        const opt = {
          label: displayLabel(lib.library),
          stroke: getColor(lib.library),
          width: 2,
          points: { show: true, size: 6 },
          spanGaps: false,
        };
        if (isBlocking(lib.library)) opt.dash = [6, 4];
        return opt;
      })
    );

    return {
      width: host.clientWidth || 800,
      height: 360,
      series,
      scales: {
        x: { time: false },
        y: { distr: logScale ? 3 : 1 },
      },
      axes: [
        {
          values: (_, ticks) => ticks.map((t) => xLabels[t - 1] || ''),
          label: 'producer/consumer shape',
        },
        {
          label: 'throughput (ops/ms)' + (logScale ? ' [log]' : ''),
          values: (_, ticks) =>
            ticks.map((v) => (v >= 1000 ? v.toExponential(1) : '' + v)),
        },
      ],
      cursor: { drag: { x: false, y: false } },
      legend: { show: false },
      plugins: [tooltipPlugin(libraries, xLabels)],
    };
  }

  function attachResizeObserver(host, getPlot) {
    if (typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(() => {
      const plot = getPlot();
      if (plot) plot.setSize({ width: host.clientWidth, height: 360 });
    });
    ro.observe(host);
  }

  /* Render one throughput panel for a topology group.
   * `libsByShape` is Map<library, Map<shape, MeasureValue>>.
   */
  function renderThroughputPanel(host, panel, libsByShape) {
    host.innerHTML = '';
    host.appendChild(el('h4', { class: 'bench-panel-title' }, panel.label));

    if (!libsByShape || libsByShape.size === 0) {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        'No data for this topology yet.'));
      return;
    }
    if (typeof window.uPlot !== 'function') {
      host.appendChild(el('p', { class: 'bench-chart-error' },
        'Chart unavailable: uPlot library failed to load.'));
      return;
    }

    // Collect shapes and assemble per-library point arrays.
    const shapeSet = new Set();
    const libraries = [];
    for (const [library, shapeMap] of libsByShape) {
      const points = [];
      for (const [shape, mv] of shapeMap) {
        if (!mv || typeof mv.value !== 'number' || mv.value <= 0) continue;
        shapeSet.add(shape);
        points.push({
          shape,
          value: mv.value,
          lower: mv.lower,
          upper: mv.upper,
          slug: mv.slug,
        });
      }
      if (points.length === 0) continue;
      libraries.push({
        library,
        points,
        panelId: panel.id,
      });
    }
    libraries.sort((a, b) => a.library.localeCompare(b.library));

    if (libraries.length === 0) {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        'No plottable values for this topology.'));
      return;
    }

    const xLabels = sortShapeLabels(shapeSet);
    const xs = xLabels.map((_, i) => i + 1);
    const seriesData = libraries.map((lib) => {
      const byShape = new Map(lib.points.map((p) => [p.shape, p]));
      return xLabels.map((label) => {
        const p = byShape.get(label);
        return p ? p.value : null;
      });
    });
    const data = [xs, ...seriesData];

    let logScale = true;
    let plot;

    const plotMount = el('div', { class: 'bench-chart-plot' });
    const rebuild = () => {
      if (plot) plot.destroy();
      plotMount.innerHTML = '';
      plot = new window.uPlot(
        makeThroughputOpts(plotMount, libraries, xLabels, logScale),
        data,
        plotMount
      );
    };

    const controls = buildControls(panel.id, logScale, (next) => {
      logScale = next;
      rebuild();
    });
    const legend = buildLegend(libraries, (i, show) => {
      if (plot) plot.setSeries(i + 1, { show });
    });

    host.appendChild(controls);
    host.appendChild(plotMount);
    host.appendChild(legend);
    rebuild();
    attachResizeObserver(plotMount, () => plot);
  }

  // ── module: latency placeholder (filled in A2) ──────────────────────

  function renderLatencyPlaceholder(host) {
    if (!host) return;
    host.innerHTML = '';
    host.appendChild(el('h4', { class: 'bench-panel-title' }, 'Latency'));
    host.appendChild(el('p', { class: 'bench-chart-empty' },
      'Latency rendering coming in the next commit.'));
  }

  // ── module: fallback chain ──────────────────────────────────────────

  async function loadBMF() {
    try {
      const resp = await fetch(SNAPSHOT_URL, { cache: 'no-cache' });
      if (resp.ok) {
        const data = await resp.json();
        if (data && data._status === 'fallback') {
          const cause = data._reason
            || (data._merge_outcome
                ? 'merge_bmf outcome=' + data._merge_outcome
                : 'snapshot pipeline produced fallback');
          return await tryFixture(cause);
        }
        return { data, status: 'live', reason: null };
      }
      return await tryFixture('latest.json HTTP ' + resp.status);
    } catch (err) {
      return await tryFixture('latest.json fetch failed: ' +
        (err && err.message ? err.message : err));
    }
  }

  async function tryFixture(reason) {
    try {
      const resp = await fetch(FIXTURE_URL, { cache: 'no-cache' });
      if (!resp.ok) throw new Error('example.json HTTP ' + resp.status);
      const data = await resp.json();
      return { data, status: 'fixture', reason };
    } catch (err) {
      return {
        data: null,
        status: 'error',
        reason: reason + '; example.json also unavailable: ' +
          (err && err.message ? err.message : err),
      };
    }
  }

  function renderStatusBanner(host, status, reason) {
    if (!host) return;
    if (status === 'live') {
      host.setAttribute('hidden', '');
      host.removeAttribute('data-status');
      host.innerHTML = '';
      return;
    }
    host.removeAttribute('hidden');
    host.setAttribute('data-status', status);
    host.innerHTML = '';
    let message;
    if (status === 'fixture') {
      message =
        'Showing representative data from example.json. Live snapshot ' +
        'was unavailable (' + reason + '). The chart will refresh once ' +
        'the next bench run on devel publishes latest.json.';
    } else if (status === 'error') {
      message =
        'Bench snapshot pending — the most recent attempt to merge ' +
        'benchmark results was unavailable (' + reason +
        '). Live data will appear here on the next successful run.';
    } else {
      message = 'Bench snapshot status: ' + status + ' (' + reason + ').';
    }
    host.appendChild(el('p', null, message));
  }

  function renderAllEmpty(reason) {
    const heroHost = document.getElementById('bench-hero');
    if (heroHost) {
      heroHost.innerHTML = '';
      heroHost.appendChild(el('p', { class: 'bench-hero-empty' },
        'Bench snapshot pending — ' + reason));
    }
    for (const panel of THROUGHPUT_PANELS) {
      const host = document.getElementById(panel.id);
      if (host) {
        host.innerHTML = '';
        host.appendChild(el('h4', { class: 'bench-panel-title' }, panel.label));
        host.appendChild(el('p', { class: 'bench-chart-empty' },
          'Awaiting next bench run.'));
      }
    }
    renderLatencyPlaceholder(document.getElementById('bench-latency'));
  }

  // ── module: bootstrap ───────────────────────────────────────────────

  async function render() {
    const heroHost = document.getElementById('bench-hero');
    const statusHost = document.getElementById('bench-status');
    const hasAnyHost = heroHost ||
      THROUGHPUT_PANELS.some((p) => document.getElementById(p.id)) ||
      document.getElementById('bench-latency');
    if (!hasAnyHost) return;

    // Always render the latency placeholder so the section isn't empty.
    renderLatencyPlaceholder(document.getElementById('bench-latency'));

    const result = await loadBMF();
    if (result.status === 'error') {
      renderStatusBanner(statusHost, 'error', result.reason);
      renderAllEmpty(result.reason);
      return;
    }

    renderStatusBanner(statusHost, result.status, result.reason);
    const byTopology = groupByTopology(result.data || {});

    if (heroHost) renderHero(heroHost, byTopology);

    for (const panel of THROUGHPUT_PANELS) {
      const host = document.getElementById(panel.id);
      if (!host) continue;
      // Collect every topology that this panel includes (e.g. the
      // SPSC panel includes both spsc and spsc_unbounded so bounded
      // and unbounded SPSC libraries render side-by-side).
      const merged = new Map();
      for (const [topology, libsByShape] of byTopology) {
        if (!panel.includes(topology)) continue;
        for (const [library, shapeMap] of libsByShape) {
          let dest = merged.get(library);
          if (!dest) { dest = new Map(); merged.set(library, dest); }
          for (const [shape, mv] of shapeMap) dest.set(shape, mv);
        }
      }
      renderThroughputPanel(host, panel, merged);
    }

    // Hash routing: native scroll-to-id is enough because the IDs match
    // the URL fragments. We just nudge the browser to re-evaluate the
    // hash now that panels are populated (otherwise an initial load
    // with #bench-throughput-spsc lands above the rendered panel).
    if (window.location.hash) {
      const id = window.location.hash.slice(1);
      const node = document.getElementById(id);
      if (node) {
        // Defer to next frame so uPlot has finished sizing.
        requestAnimationFrame(() => {
          node.scrollIntoView({ behavior: 'smooth', block: 'start' });
        });
      }
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }
})();
