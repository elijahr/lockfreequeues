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
    // `nim_channels` (plural) is the harness ID for Nim's stdlib
    // `system/Channel` on platforms where the singular slug collides
    // with another adapter. Same library, same blocking-on-full
    // semantics — keep the color in sync with `nim_channel`.
    nim_channels:                    '#546e7a',
  });
  // CONTRACT-TEST-PARSED-END LIBRARY_COLORS

  // CONTRACT-TEST-PARSED-START BLOCKING_LIBRARIES
  const BLOCKING_LIBRARIES = ['threading_channels', 'nim_channel', 'nim_channels'];
  // CONTRACT-TEST-PARSED-END BLOCKING_LIBRARIES
  const BLOCKING_SET = new Set(BLOCKING_LIBRARIES);

  const LOCKFREEQUEUES_FAMILY = [
    'lockfreequeues_sipsic', 'lockfreequeues_sipmuc',
    'lockfreequeues_mupsic', 'lockfreequeues_mupmuc',
    'lockfreequeues_unbounded_sipsic', 'lockfreequeues_unbounded_sipmuc',
    'lockfreequeues_unbounded_mupsic', 'lockfreequeues_unbounded_mupmuc',
  ];
  const LFQ_FAMILY_SET = new Set(LOCKFREEQUEUES_FAMILY);

  // Hero is "lockfreequeues vs alternatives at a canonical bounded
  // shape." Bounded topologies only — the per-topology panels below
  // already show bounded vs unbounded side-by-side; mixing them in the
  // hero adds DEBRA-reclamation overhead noise that obscures the
  // headline comparison.
  const HERO_SHAPE_PREFERENCE = [
    { topology: 'mpmc',           shape: '4p4c' },
    { topology: 'mpmc',           shape: '2p2c' },
    { topology: 'mpsc',           shape: '4p1c' },
    { topology: 'spsc',           shape: '1p1c' },
  ];

  // Pretty labels for topology slugs used in headings and tooltips.
  const TOPOLOGY_LABELS = Object.freeze({
    spsc: 'SPSC',
    mpsc: 'MPSC',
    mpmc: 'MPMC',
    spmc: 'SPMC',
    spsc_unbounded: 'SPSC (unbounded)',
    mpsc_unbounded: 'MPSC (unbounded)',
    spmc_unbounded: 'SPMC (unbounded)',
    mpmc_unbounded: 'MPMC (unbounded)',
  });

  function topologyLabel(topology) {
    return TOPOLOGY_LABELS[topology] || topology.toUpperCase();
  }

  function isBoundedTopology(topology) {
    return !topology.endsWith('_unbounded');
  }

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
    { id: 'bench-throughput-spmc',           label: 'SPMC',
      includes: (topology) => topology === 'spmc'
                              || topology === 'spmc_unbounded' },
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
      // Hero is bounded-only (see HERO_SHAPE_PREFERENCE comment).
      // Skip unbounded topologies even in the fallback search so the
      // headline comparison never silently picks an unbounded shape.
      if (!isBoundedTopology(topology)) continue;
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

  // Build a hover-tooltip string for one library at the hero shape.
  // Mirrors the uPlot tooltip format so the hero and panels speak the
  // same language: "<library>: <value> ops/ms (±stddev) — <topology shape>".
  function heroRowTitle(library, mv, topology, shape) {
    let line = library + ': ' + mv.value.toFixed(1) + ' ops/ms';
    if (mv.lower != null && mv.upper != null) {
      const stddev = (mv.upper - mv.lower) / 2;
      line += ' (±' + stddev.toFixed(1) + ')';
    }
    line += ' — ' + topologyLabel(topology) + ' ' + shape;
    if (isBlocking(library)) line += ' (blocking)';
    return line;
  }

  // Build the offscreen ARIA companion table for the hero canvas. Screen
  // readers consume the rows via `aria-describedby`; the table is
  // visually offscreen but kept in the accessibility tree.
  function buildHeroAriaTable(rows) {
    const table = el('table', {
      id: 'bench-hero-aria-table',
      class: 'bench-hero-aria-table',
      'aria-hidden': 'false',
      style: 'position: absolute; left: -9999px; top: auto; ' +
        'width: 1px; height: 1px; overflow: hidden;',
    });
    const thead = el('thead', null,
      el('tr', null,
        el('th', null, 'Library'),
        el('th', null, 'Throughput (ops/ms)')));
    const tbody = el('tbody');
    for (const r of rows) {
      tbody.appendChild(el('tr', null,
        el('td', null, r.library),
        el('td', null, r.value.toFixed(1))));
    }
    table.appendChild(thead);
    table.appendChild(tbody);
    return table;
  }

  // Hero panel renderer: canvas-rendered uPlot vertical bars when the
  // library is available, with an offscreen ARIA companion table for
  // screen-reader consumers. Falls back to DOM `<ol>` bars (the
  // pre-canvas rendering) when uPlot or `paths.bars` is unavailable.
  function renderHero(host, byTopology) {
    host.innerHTML = '';
    const pick = pickHeroShape(byTopology);
    if (!pick) {
      host.appendChild(el('h3', { class: 'bench-hero-heading' },
        'Throughput at a glance'));
      host.appendChild(el('p', { class: 'bench-hero-empty' },
        'No comparable cross-library data at any shape — see throughput panels below.'));
      return;
    }
    const inTopology = byTopology.get(pick.topology);
    const rows = [];
    for (const [library, shapeMap] of inTopology.entries()) {
      const mv = shapeMap.get(pick.shape);
      if (!mv || typeof mv.value !== 'number') continue;
      rows.push({
        library,
        value: mv.value,
        lower: mv.lower,
        upper: mv.upper,
        slug: mv.slug,
      });
    }

    // Heading: "MPMC 4p4c — lockfreequeues vs alternatives". When no
    // alternative is present (lfq-only at this shape) the suffix
    // collapses gracefully.
    const hasAlt = rows.some((r) => !isLockfreequeues(r.library));
    const headingText = topologyLabel(pick.topology) + ' ' + pick.shape +
      (hasAlt ? ' — lockfreequeues vs alternatives'
              : ' — lockfreequeues throughput');
    host.appendChild(el('h3', { class: 'bench-hero-heading' }, headingText));

    if (rows.length === 0) {
      host.appendChild(el('p', { class: 'bench-hero-empty' },
        'No data at the chosen hero shape.'));
      return;
    }

    // Sort descending by mean throughput so the strongest library sits
    // leftmost. Ties are broken alphabetically for determinism.
    rows.sort((a, b) => (b.value - a.value)
      || a.library.localeCompare(b.library));
    const sawBlocking = rows.some((r) => isBlocking(r.library));

    const canBars =
      typeof window.uPlot === 'function'
      && window.uPlot.paths
      && typeof window.uPlot.paths.bars === 'function';

    if (canBars) {
      renderHeroCanvas(host, rows, pick);
    } else {
      // Escape hatch (impl plan line 338): keep the legacy DOM
      // `<ol>`-bar renderer when uPlot bars are unavailable.
      renderHeroDomBars(host, rows, pick);
    }

    // Y-axis equivalent: a small caption under the bars naming the
    // unit. Matches the throughput panels' "throughput (ops/ms)" label.
    host.appendChild(el('p', { class: 'bench-hero-axis-caption' },
      'throughput (ops/ms)'));

    // Always emit the legend with a stable structure, regardless of
    // whether a blocking library appears. Blocking rows carry a
    // "(blocking)" badge; the legend itself documents what the dotted
    // bar means, so there is no inline footnote.
    host.appendChild(buildHeroLegend(rows, sawBlocking));

    // Offscreen ARIA table: every render path gets one so screen
    // readers can read the values regardless of canvas vs. DOM bars.
    host.appendChild(buildHeroAriaTable(rows));
  }

  function renderHeroDomBars(host, rows, pick) {
    const max = Math.max.apply(null, rows.map((r) => r.value));
    const list = el('ol', { class: 'bench-hero-bars' });
    for (const r of rows) {
      const pct = max > 0 ? (r.value / max * 100) : 0;
      const blocking = isBlocking(r.library);
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
        title: heroRowTitle(r.library, r, pick.topology, pick.shape),
      },
        el('span', { class: 'bench-hero-label' }, r.library),
        el('span', { class: barClass, style: barStyle }),
        el('span', { class: 'bench-hero-value' },
          r.value.toFixed(1) + ' ops/ms')
      );
      list.appendChild(li);
    }
    host.appendChild(list);
  }

  // Tooltip plugin for the hero canvas: indexes back into the rows to
  // surface "<library>: <value> ops/ms (±stddev) — <topology shape>".
  function heroTooltipPlugin(rows, pick) {
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
          const r = rows[idx];
          if (!r) { tip.style.display = 'none'; return; }
          tip.innerHTML = '<strong>' + escapeHtml(r.library) + '</strong><br>' +
            escapeHtml(heroRowTitle(r.library, r, pick.topology, pick.shape));
          tip.style.display = 'block';
          tip.style.left = left + 12 + 'px';
          tip.style.top = top + 12 + 'px';
        },
      },
    };
  }

  // Render the hero panel as a uPlot canvas with one series per
  // library (each carrying a single non-null value at its own x slot)
  // so each bar can pick up its own stroke/fill color and dashed-stroke
  // for blocking libraries.
  function renderHeroCanvas(host, rows, pick) {
    const wrap = el('div', { class: 'bench-hero-canvas-wrap' });
    const plotMount = el('div', {
      class: 'bench-chart-plot bench-hero-plot',
      role: 'img',
      'aria-describedby': 'bench-hero-aria-table',
      'aria-label': 'Hero throughput chart, ' + rows.length +
        ' libraries, see offscreen table for values',
    });
    wrap.appendChild(plotMount);
    host.appendChild(wrap);

    const xLabels = rows.map((r) => r.library);
    const xs = rows.map((_, i) => i + 1);
    // One series per library: each series carries a single non-null
    // value at its own slot so it can render its own colored bar.
    const seriesData = rows.map((r, i) =>
      rows.map((_, j) => (i === j ? r.value : null))
    );
    const data = [xs, ...seriesData];

    const bars = barsPath({ size: [0.85, 60, 1], gap: 4 });
    const series = [{ label: 'library' }].concat(
      rows.map((r) => {
        const blocking = isBlocking(r.library);
        const stroke = getColor(r.library);
        const opt = {
          label: displayLabel(r.library),
          stroke,
          width: 2,
          points: { show: false },
          spanGaps: false,
          fill: blocking ? 'transparent' : stroke,
        };
        if (bars) opt.paths = bars;
        if (blocking) opt.dash = [6, 4];
        return opt;
      })
    );

    const plot = new window.uPlot(
      {
        width: plotMount.clientWidth || (host.clientWidth || 800),
        height: 320,
        series,
        scales: {
          x: { time: false },
          y: { distr: 1 },
        },
        axes: [
          {
            values: (_, ticks) => ticks.map((t) => xLabels[t - 1] || ''),
            label: 'library',
          },
          {
            label: 'throughput (ops/ms)',
            values: (_, ticks) =>
              ticks.map((v) => (v >= 1000 ? v.toExponential(1) : '' + v)),
          },
        ],
        cursor: { drag: { x: false, y: false } },
        legend: { show: false },
        plugins: [heroTooltipPlugin(rows, pick)],
      },
      data,
      plotMount
    );

    if (typeof ResizeObserver !== 'undefined') {
      const ro = new ResizeObserver(() => {
        plot.setSize({
          width: plotMount.clientWidth || (host.clientWidth || 800),
          height: 320,
        });
      });
      ro.observe(plotMount);
    }
  }

  function buildHeroLegend(rows, sawBlocking) {
    const wrap = el('div', { class: 'bench-hero-legend' });
    for (const r of rows) {
      const blocking = isBlocking(r.library);
      const swatch = el('span', {
        class: 'bench-chart-swatch' +
          (blocking ? ' bench-chart-swatch-blocking' : ''),
        style: blocking
          ? 'color: ' + getColor(r.library) + ';'
          : 'background: ' + getColor(r.library) + ';',
      });
      const children = [swatch, document.createTextNode(r.library)];
      if (blocking) {
        children.push(el('span', { class: 'bench-hero-blocking-badge' },
          '(blocking)'));
      }
      wrap.appendChild(el('span', { class: 'bench-legend-item' },
        ...children));
    }
    if (sawBlocking) {
      wrap.appendChild(el('p', { class: 'bench-hero-legend-note' },
        'Dotted bars mark libraries that block on full; throughput ' +
        'reflects blocking semantics, not the non-blocking try_push path.'));
    }
    return wrap;
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

  // Escape any HTML metacharacters so library names can be inlined in
  // the tooltip's innerHTML without risk of injection. The values that
  // reach this function are constrained by the slug grammar (`[a-z0-9_]+`)
  // so no escape is strictly required today, but the helper future-proofs
  // the path against fixture or BMF schema drift.
  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function tooltipPlugin(libraries, xLabels, panelLabel) {
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
            // Tooltip line: "<library>: <value> ops/ms (±stddev) (blocking)?".
            // Stddev only when the BMF carried lower/upper bounds.
            let line = escapeHtml(lib.library) + ': ' +
              point.value.toFixed(1) + ' ops/ms';
            if (point.lower != null && point.upper != null) {
              const stddev = (point.upper - point.lower) / 2;
              line += ' (±' + stddev.toFixed(1) + ')';
            }
            if (isBlocking(lib.library)) line += ' (blocking)';
            lines.push(line);
          }
          if (lines.length === 0) {
            tip.style.display = 'none';
            return;
          }
          // Header: "<panel label> <shape>" e.g. "MPMC (bounded) 4p4c",
          // so the user always knows the topology context without
          // looking at the panel title.
          const header = panelLabel
            ? escapeHtml(panelLabel) + ' ' + escapeHtml(shape)
            : escapeHtml(shape);
          tip.innerHTML =
            '<strong>' + header + '</strong><br>' + lines.join('<br>');
          tip.style.display = 'block';
          tip.style.left = left + 12 + 'px';
          tip.style.top = top + 12 + 'px';
        },
      },
    };
  }

  // Build a uPlot vertical-bar paths function. Categorical X axis pairs
  // with a (log or linear) Y axis; non-blocking libraries render as
  // filled bars, blocking libraries get a stroked-but-transparent bar
  // (with the dashed stroke applied at the series level) so they read
  // as outlined rather than solid.
  function barsPath(opts) {
    if (!window.uPlot || !window.uPlot.paths || !window.uPlot.paths.bars) {
      return null;
    }
    return window.uPlot.paths.bars(opts || { size: [0.6, 60, 1], gap: 2 });
  }

  function makeThroughputOpts(host, libraries, xLabels, logScale, panelLabel) {
    const bars = barsPath({ size: [0.6, 60, 1], gap: 2 });
    const series = [{ label: 'shape' }].concat(
      libraries.map((lib) => {
        const stroke = getColor(lib.library);
        const blocking = isBlocking(lib.library);
        const opt = {
          label: displayLabel(lib.library),
          stroke,
          width: 2,
          // Bars carry their own footprint; per-point dots add visual
          // noise on a categorical bar chart, so disable them.
          points: { show: false },
          spanGaps: false,
          // Blocking libraries get a transparent fill so the dashed
          // stroke reads as an outlined bar; non-blocking libraries
          // fill with the same hue as the stroke for solid bars.
          fill: blocking ? 'transparent' : stroke,
        };
        if (bars) opt.paths = bars;
        if (blocking) opt.dash = [6, 4];
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
          label: 'producer/consumer shape (P×C)',
        },
        {
          label: 'throughput (ops/ms)' + (logScale ? ' — log scale' : ''),
          // On log-scale axes, only major (power-of-10) tick labels
          // render. Null/non-finite values and minor ticks (e.g.
          // 2e3, 5e3 between 1e3 and 1e4) collapse to empty strings
          // so the axis stays clean and readable.
          values: (_, ticks) =>
            ticks.map((v) => {
              if (v == null || !Number.isFinite(v)) return '';
              const log = Math.log10(v);
              if (Math.abs(log - Math.round(log)) > 1e-9) return '';
              return v >= 1000 ? v.toExponential(1) : '' + v;
            }),
        },
      ],
      cursor: { drag: { x: false, y: false } },
      legend: { show: false },
      plugins: [tooltipPlugin(libraries, xLabels, panelLabel)],
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
        makeThroughputOpts(plotMount, libraries, xLabels, logScale, panel.label),
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

  // ── module: latency panel (uPlot stepped ladder) ────────────────────

  // Percentile axis — fixed order p50 → p95 → p99 → p999 → max. The
  // categorical x-axis uses integer ticks 1..5 mapping to these labels.
  const LATENCY_PERCENTILES = Object.freeze([
    { key: 'latency_p50_ns',  label: 'p50'  },
    { key: 'latency_p95_ns',  label: 'p95'  },
    { key: 'latency_p99_ns',  label: 'p99'  },
    { key: 'latency_p999_ns', label: 'p999' },
    { key: 'latency_max_ns',  label: 'max'  },
  ]);

  /* Build the per-library latency series from a BMF snapshot.
   * Returns { libraries, hadAny } where:
   *   libraries: Array<{ library, slug, values: Array<number|null> }>
   *              with values aligned to LATENCY_PERCENTILES order.
   *   hadAny: true if at least one slug carried any latency_* measure.
   *
   * Filtering rules:
   *   - Only slugs with at least one latency_* measure contribute.
   *   - A library appears once even if multiple slugs match (rare —
   *     latency is collected for bounded 1p1c only); the first slug
   *     wins, deterministic by sort order.
   *   - Missing percentiles within an otherwise-present series become
   *     null gaps so uPlot's stepped path skips them gracefully.
   */
  function collectLatencySeries(bmf) {
    const byLibrary = new Map();
    let hadAny = false;
    const slugs = Object.keys(bmf).filter((s) => !s.startsWith('_')).sort();
    for (const slug of slugs) {
      const measureMap = bmf[slug];
      if (!measureMap || typeof measureMap !== 'object') continue;
      const hasLatency = LATENCY_PERCENTILES.some((p) => {
        const m = measureMap[p.key];
        return m && typeof m.value === 'number' && Number.isFinite(m.value);
      });
      if (!hasLatency) continue;
      hadAny = true;
      const parsed = parseSlug(slug);
      if (!parsed) continue;
      if (byLibrary.has(parsed.library)) continue;
      const values = LATENCY_PERCENTILES.map((p) => {
        const m = measureMap[p.key];
        if (!m || typeof m.value !== 'number' || !Number.isFinite(m.value)) {
          return null;
        }
        if (m.value <= 0) return null;
        return m.value;
      });
      byLibrary.set(parsed.library, {
        library: parsed.library,
        slug,
        values,
      });
    }
    const libraries = Array.from(byLibrary.values())
      .sort((a, b) => a.library.localeCompare(b.library));
    return { libraries, hadAny };
  }

  function latencyTooltipPlugin(libraries, xLabels) {
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
          const label = xLabels[idx];
          const lines = [];
          for (let i = 0; i < libraries.length; i++) {
            const s = u.series[i + 1];
            if (!s.show) continue;
            const lib = libraries[i];
            const v = lib.values[idx];
            if (v == null) continue;
            lines.push(displayLabel(lib.library) + ': ' +
              v.toFixed(0) + ' ns');
          }
          if (lines.length === 0) {
            tip.style.display = 'none';
            return;
          }
          tip.innerHTML =
            '<strong>' + label + '</strong><br>' + lines.join('<br>');
          tip.style.display = 'block';
          tip.style.left = left + 12 + 'px';
          tip.style.top = top + 12 + 'px';
        },
      },
    };
  }

  function makeLatencyOpts(host, libraries, xLabels) {
    // Prefer uPlot's stepped path when available (1.6.27 ships it on
    // the global uPlot.paths). Fall back to default linear path if the
    // helper is missing — the ladder shape is still readable.
    const stepped =
      (window.uPlot && window.uPlot.paths && window.uPlot.paths.stepped)
        ? window.uPlot.paths.stepped({ align: 1 })
        : null;
    const series = [{ label: 'percentile' }].concat(
      libraries.map((lib) => {
        const opt = {
          label: displayLabel(lib.library),
          stroke: getColor(lib.library),
          width: 2,
          points: { show: true, size: 6 },
          spanGaps: false,
        };
        if (stepped) opt.paths = stepped;
        if (isBlocking(lib.library)) opt.dash = [6, 4];
        return opt;
      })
    );

    return {
      width: host.clientWidth || 800,
      height: 360,
      series,
      // Log-scale Y axis — latency tail dynamics span 3-4 decades, so
      // a linear scale would compress p50/p95 against the noise floor
      // and obscure the tail behavior that matters for production
      // sizing. distr: 3 = log scale in uPlot.
      scales: {
        x: { time: false },
        y: { distr: 3 },
      },
      axes: [
        {
          values: (_, ticks) => ticks.map((t) => xLabels[t - 1] || ''),
          label: 'percentile',
        },
        {
          label: 'latency (ns) [log]',
          // On log-scale axes, only major (power-of-10) tick labels
          // render. See `makeThroughputOpts` for the same suppression
          // logic — keeps the axis clean across both panel types.
          values: (_, ticks) =>
            ticks.map((v) => {
              if (v == null || !Number.isFinite(v)) return '';
              const log = Math.log10(v);
              if (Math.abs(log - Math.round(log)) > 1e-9) return '';
              return v >= 1000 ? v.toExponential(1) : '' + v;
            }),
        },
      ],
      cursor: { drag: { x: false, y: false } },
      legend: { show: false },
      plugins: [latencyTooltipPlugin(libraries, xLabels)],
    };
  }

  // CONTRACT-TEST-PARSED-START LATENCY_EMPTY_MESSAGE
  const LATENCY_EMPTY_MESSAGE =
    'Latency measurements unavailable in this dataset. Latency data is ' +
    'collected only for bounded 1p1c variants in the bench_latency ' +
    'binary; rerun the bench to populate.';
  // CONTRACT-TEST-PARSED-END LATENCY_EMPTY_MESSAGE

  const LATENCY_PARTIAL_FOOTNOTE =
    "Some libraries don't yet have latency measurements — adapter " +
    'coverage is in progress.';

  /* Render the latency panel. `bmf` is the raw snapshot object so the
   * latency renderer can pick its own measure keys (different from the
   * throughput pipeline's CHART_MEASURE).
   *
   * Empty-state triggers:
   *   - bmf null/undefined or no slugs → "unavailable" message.
   *   - no slug carries any latency_* measure → "unavailable" message.
   * Partial-state trigger:
   *   - latency present but fewer libraries than expected coverage —
   *     we surface a soft footnote rather than blocking the render.
   *     Threshold: lockfreequeues family alone (4 bounded 1p1c slugs)
   *     → no footnote; if any non-lfq library carries latency we don't
   *     warn either; the footnote fires only when at least one
   *     lockfreequeues library is missing latency data while others
   *     have it (i.e. coverage is incomplete inside the family).
   */
  function renderLatencyPanel(host, bmf) {
    if (!host) return;
    host.innerHTML = '';
    host.appendChild(el('h4', { class: 'bench-panel-title' }, 'Latency'));

    if (!bmf || typeof bmf !== 'object') {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        LATENCY_EMPTY_MESSAGE));
      return;
    }

    const { libraries, hadAny } = collectLatencySeries(bmf);
    if (!hadAny || libraries.length === 0) {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        LATENCY_EMPTY_MESSAGE));
      return;
    }
    if (typeof window.uPlot !== 'function') {
      host.appendChild(el('p', { class: 'bench-chart-error' },
        'Chart unavailable: uPlot library failed to load.'));
      return;
    }

    const xLabels = LATENCY_PERCENTILES.map((p) => p.label);
    const xs = xLabels.map((_, i) => i + 1);
    const seriesData = libraries.map((lib) => lib.values.slice());
    const data = [xs, ...seriesData];

    let plot;
    const plotMount = el('div', { class: 'bench-chart-plot' });
    const rebuild = () => {
      if (plot) plot.destroy();
      plotMount.innerHTML = '';
      plot = new window.uPlot(
        makeLatencyOpts(plotMount, libraries, xLabels),
        data,
        plotMount
      );
    };

    // Decorate libraries with the panelId expected by buildLegend.
    const legendLibs = libraries.map((lib) => ({
      library: lib.library,
      panelId: 'bench-latency',
    }));
    const legend = buildLegend(legendLibs, (i, show) => {
      if (plot) plot.setSeries(i + 1, { show });
    });

    host.appendChild(plotMount);
    host.appendChild(legend);

    // Partial-coverage footnote: at least one lfq bounded variant
    // carries latency, but not all four. This is the visible
    // "adapter coverage in progress" cue.
    const lfqBoundedExpected = [
      'lockfreequeues_sipsic', 'lockfreequeues_sipmuc',
      'lockfreequeues_mupsic', 'lockfreequeues_mupmuc',
    ];
    const present = new Set(libraries.map((l) => l.library));
    const lfqHits = lfqBoundedExpected.filter((l) => present.has(l)).length;
    if (lfqHits > 0 && lfqHits < lfqBoundedExpected.length) {
      host.appendChild(el('p', { class: 'bench-hero-footnote' },
        LATENCY_PARTIAL_FOOTNOTE));
    }

    rebuild();
    attachResizeObserver(plotMount, () => plot);
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
      heroHost.appendChild(el('h3', { class: 'bench-hero-heading' },
        'Throughput at a glance'));
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
    renderLatencyPanel(document.getElementById('bench-latency'), null);
  }

  // ── module: bootstrap ───────────────────────────────────────────────

  async function render() {
    const heroHost = document.getElementById('bench-hero');
    const statusHost = document.getElementById('bench-status');
    const hasAnyHost = heroHost ||
      THROUGHPUT_PANELS.some((p) => document.getElementById(p.id)) ||
      document.getElementById('bench-latency');
    if (!hasAnyHost) return;

    // Pre-paint the latency panel with the empty-state message so the
    // section isn't blank during fetch (or if fetch fails entirely).
    renderLatencyPanel(document.getElementById('bench-latency'), null);

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

    // Latency panel — re-render with the loaded BMF (replaces the
    // pre-paint empty state from the top of `render`).
    renderLatencyPanel(
      document.getElementById('bench-latency'),
      result.data || null
    );

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
