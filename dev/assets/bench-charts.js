/* lockfreequeues bench charts — uPlot wiring for docs/benchmarks.md.
 *
 * Loads the merged Bencher Metric Format (BMF) snapshot from
 * `../assets/bench-results/latest.json` — page lives at
 * `/<version>/benchmarks/` under mike + mkdocs `use_directory_urls`,
 * so we go up one level to reach `/<version>/assets/`. The same
 * relative path works under /dev/, /latest/, and /v*\/ aliases,
 * groups slugs by library, and renders a single uPlot line chart of
 * throughput_ops_ms across (P,C) shapes. The X axis is the producer/
 * consumer-count index; the Y axis is throughput in ops/ms with an
 * optional log-scale toggle. Each library is one series; a checkbox
 * legend hides/shows libraries on demand.
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
 *   - fetch fails -> render an inline message; no console-error spam.
 *   - JSON parses but contains zero throughput slugs -> "no data yet" message.
 *   - uPlot global missing -> message asking the page to load uPlot first.
 */

(function () {
  'use strict';

  const SNAPSHOT_URL = '../assets/bench-results/latest.json';
  const CHART_MEASURE = 'throughput_ops_ms';

  // Stable colour palette (uPlot has no default cycle for many series).
  // Picked to be distinguishable on the slate-dark Material theme.
  const PALETTE = [
    '#7eb6ff', '#ff9f7e', '#9ee37e', '#d77eff', '#ffeb7e',
    '#7effd9', '#ff7e9c', '#bfff7e', '#7e9cff', '#ffb87e',
    '#7effff', '#ff7eb8', '#c7ff7e', '#a87eff', '#ffd97e',
    '#7effb8',
  ];

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
    // `<library>/<topology>/<P>p<C>c` — the first segment is the
    // library; the last is the shape. We do not depend on a fixed
    // segment count because future taxonomy may add internal segments.
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

  /* Build the data grid the chart consumes. Returns:
   *   xLabels:   sorted array of unique shape strings (e.g. "1p1c").
   *   xKeys:     numeric x positions (1..xLabels.length).
   *   libraries: array of { name, points: Array<{x,y,lower?,upper?,slug}> }.
   * The caller decides which libraries to actually plot via the toggle
   * legend; we always materialise the full set so toggles cost nothing.
   */
  function buildSeries(bmf) {
    const byLibrary = new Map();
    const shapeSet = new Set();

    for (const slug in bmf) {
      const measureMap = bmf[slug];
      if (!measureMap || typeof measureMap !== 'object') continue;
      const m = measureMap[CHART_MEASURE];
      if (!m || typeof m.value !== 'number' || !Number.isFinite(m.value)) continue;
      const parsed = parseSlug(slug);
      if (!parsed) continue;
      shapeSet.add(parsed.shape);
      // Composite key: library + topology, so a single library
      // exposing multiple topologies (e.g. `lockfreequeues_mupmuc/spsc`
      // AND `lockfreequeues_mupmuc/mpmc`) renders as separate series
      // instead of silently overwriting one shape with another.
      const seriesKey = parsed.library + ' (' + parsed.topology + ')';
      let lib = byLibrary.get(seriesKey);
      if (!lib) {
        lib = { name: seriesKey, points: [] };
        byLibrary.set(seriesKey, lib);
      }
      lib.points.push({
        slug,
        shape: parsed.shape,
        totalThreads: parsed.totalThreads,
        p: parsed.p,
        c: parsed.c,
        value: m.value,
        lower: typeof m.lower_value === 'number' ? m.lower_value : null,
        upper: typeof m.upper_value === 'number' ? m.upper_value : null,
      });
    }

    // Shape ordering: sort by total thread count, then by P, then by C.
    // This puts 1p1c before 2p2c before 4p4c naturally and groups
    // P-skewed shapes near their balanced peers.
    /* Pre-parse each `<P>p<C>c` shape label into numeric sort keys so the
     * comparator doesn't re-run regex + parseInt on every comparison.
     * Non-matching labels fall back to lexicographic order via the
     * sentinel keys (-1 sorts them before any matched entry, then a
     * stable localeCompare on `label` orders them among themselves). */
    const xLabels = Array.from(shapeSet)
      .map(label => {
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
      .map(item => item.label);

    const libraries = Array.from(byLibrary.values()).sort((a, b) =>
      a.name.localeCompare(b.name)
    );

    return { xLabels, libraries };
  }

  /* Convert {xLabels, libraries} into the column-major arrays uPlot
   * expects: data[0] is the X axis; data[i+1] is the Y series for
   * libraries[i]. Missing (library, shape) cells are null, which uPlot
   * skips in line drawing. Non-positive values are also treated as
   * null: throughput in ops/ms cannot legitimately be <= 0 (a 0 means
   * a degenerate run our throughput.nim guards already reject), and
   * the chart's default Y axis is log-scale (`distr: 3`) which is
   * undefined for non-positive values. merge_bmf.py only enforces
   * finiteness, so a malformed BMF could in principle deliver a 0 or
   * negative value; rather than letting it break the log axis,
   * surface it as missing data.
   */
  function toUplotData(xLabels, libraries) {
    const x = xLabels.map((_, i) => i + 1);
    const series = libraries.map((lib) => {
      const byShape = new Map(lib.points.map((p) => [p.shape, p]));
      return xLabels.map((label) => {
        const p = byShape.get(label);
        if (!p) return null;
        return p.value > 0 ? p.value : null;
      });
    });
    return [x, ...series];
  }

  function renderError(host, message) {
    host.innerHTML = '';
    host.appendChild(
      el('div', { class: 'bench-chart-error' }, message)
    );
  }

  function buildLegend(libraries, onToggle, colours) {
    const wrap = el('div', { class: 'bench-chart-legend' });
    libraries.forEach((lib, i) => {
      const id = 'bench-legend-' + i;
      const cb = el('input', { type: 'checkbox', id });
      cb.checked = true;
      cb.addEventListener('change', () => onToggle(i, cb.checked));
      const swatch = el('span', {
        class: 'bench-chart-swatch',
        style: 'background:' + colours[i % colours.length],
      });
      const lbl = el('label', { for: id }, swatch, lib.name);
      wrap.appendChild(el('span', { class: 'bench-legend-item' }, cb, lbl));
    });
    return wrap;
  }

  function buildControls(initialLogScale, onLogToggle) {
    const wrap = el('div', { class: 'bench-chart-controls' });
    const id = 'bench-log-scale';
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
          // u.series[0] is x; series 1..N are libraries.
          const lines = [];
          for (let i = 0; i < libraries.length; i++) {
            const s = u.series[i + 1];
            if (!s.show) continue;
            const lib = libraries[i];
            // Cache an O(1) shape→point map on first hover; setCursor
            // fires on every mousemove so a per-call linear `find` is
            // wasteful even for the small per-library point counts we
            // ship today.
            if (!lib._shapeMap) {
              lib._shapeMap = new Map(lib.points.map((p) => [p.shape, p]));
            }
            const point = lib._shapeMap.get(shape);
            if (!point) continue;
            let line = lib.name + ': ' + point.value.toFixed(1) + ' ops/ms';
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

  function makeOpts(host, libraries, xLabels, logScale) {
    const colours = PALETTE;
    const series = [{ label: 'shape' }].concat(
      libraries.map((lib, i) => ({
        label: lib.name,
        stroke: colours[i % colours.length],
        width: 2,
        points: { show: true, size: 6 },
        // null gaps: uPlot's spanGaps:false leaves a missing
        // (library, shape) cell as a break in the line; this is the
        // honest representation when an adapter was soft-skipped.
        spanGaps: false,
      }))
    );

    return {
      width: host.clientWidth || 800,
      height: 420,
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
      cursor: {
        drag: { x: false, y: false },
      },
      legend: { show: false },
      plugins: [tooltipPlugin(libraries, xLabels)],
    };
  }

  /* Single persistent ResizeObserver — `getPlot` is a closure that
   * always returns the *current* uPlot instance, so the toggle's
   * rebuild() can destroy + replace `plot` without re-attaching the
   * observer. Re-attaching on every rebuild leaks an observer +
   * orphaned setSize callbacks per toggle.
   */
  function attachResizeObserver(host, getPlot) {
    if (typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(() => {
      const plot = getPlot();
      if (plot) plot.setSize({ width: host.clientWidth, height: 420 });
    });
    ro.observe(host);
  }

  async function render() {
    const host = document.getElementById('bench-chart');
    if (!host) return;

    if (typeof window.uPlot !== 'function') {
      renderError(
        host,
        'Chart unavailable: uPlot library failed to load. ' +
          'Reload the page or check the browser console.'
      );
      return;
    }

    let bmf;
    try {
      const resp = await fetch(SNAPSHOT_URL, { cache: 'no-cache' });
      if (!resp.ok) {
        renderError(
          host,
          'Chart unavailable: snapshot fetch returned HTTP ' +
            resp.status +
            '. The chart will populate after the next bench run on devel.'
        );
        return;
      }
      bmf = await resp.json();
    } catch (err) {
      renderError(
        host,
        'Chart unavailable: snapshot fetch failed (' +
          (err && err.message ? err.message : 'unknown error') +
          '). The chart will populate after the next bench run on devel.'
      );
      return;
    }

    const { xLabels, libraries } = buildSeries(bmf);
    if (libraries.length === 0 || xLabels.length === 0) {
      renderError(
        host,
        'No throughput data in snapshot yet. The chart will populate ' +
          'after the next bench run on devel.'
      );
      return;
    }

    host.innerHTML = '';
    let logScale = true;
    let plot;

    const plotMount = el('div', { class: 'bench-chart-plot' });
    const data = toUplotData(xLabels, libraries);

    const rebuild = () => {
      // Drop the previous uPlot instance before mounting the next.
      // Without destroy() the toggle accumulates uPlot DOM/listeners
      // per click; the observer attaches once below and re-resolves
      // `plot` via the closure on each setSize.
      if (plot) plot.destroy();
      plotMount.innerHTML = '';
      plot = new window.uPlot(
        makeOpts(plotMount, libraries, xLabels, logScale),
        data,
        plotMount
      );
    };

    const controls = buildControls(logScale, (next) => {
      logScale = next;
      rebuild();
    });
    const legend = buildLegend(
      libraries,
      (i, show) => {
        if (plot) plot.setSeries(i + 1, { show });
      },
      PALETTE
    );

    host.appendChild(controls);
    host.appendChild(plotMount);
    host.appendChild(legend);
    rebuild();

    // Attach the ResizeObserver once, after plotMount is mounted and
    // sized. The closure resolves `plot` on each callback so a later
    // rebuild() (log-scale toggle) just hands the observer a new
    // instance — no observer churn.
    attachResizeObserver(plotMount, () => plot);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }
})();
