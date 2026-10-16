// Port of Sources/SnipperCore/GlobeLayout.swift: equal cards in a brick grid that repeats in
// every direction; item 0 sits at the center and later items fill rings around it.
export type GlobeLayout = { cells: [number, number][]; columns: number; rows: number }

export function globeLayout(count: number, cellAspect: number): GlobeLayout {
  const n = Math.max(0, count)
  const aspect = cellAspect > 0 ? cellAspect : 1
  const [rows, columns] = shape(n, aspect)
  const base = Math.floor(n / rows)
  const extra = n % rows
  const rowIndices = Array.from({ length: rows }, (_, i) => i - Math.floor(rows / 2))
  const fuller = new Set(
    [...rowIndices].sort((a, b) => Math.abs(a) - Math.abs(b) || a - b).slice(0, extra),
  )
  const cells: [number, number][] = []
  for (const row of rowIndices) {
    const c = base + (fuller.has(row) ? 1 : 0)
    if (c === 0) continue
    const spacing = columns / c
    const offset = Math.abs(row) % 2 === 1 ? 0.5 : 0
    for (let k = -Math.floor(c / 2); k < c - Math.floor(c / 2); k++) cells.push([(k + offset) * spacing, row])
  }
  const d = ([x, y]: [number, number]) => x * x * aspect * aspect + y * y
  cells.sort((a, b) => (Math.abs(d(a) - d(b)) > 1e-9 ? d(a) - d(b) : Math.atan2(a[1], a[0]) - Math.atan2(b[1], b[0])))
  return { cells, columns, rows }
}

function shape(n: number, aspect: number): [number, number] {
  if (n <= 1) return [1, 1]
  const ideal = Math.sqrt(n * aspect)
  let best: [number, number, number, number] | null = null
  let rows = Math.max(2, Math.floor(ideal) - 2)
  if (rows % 2 === 1) rows -= 1
  for (; rows <= ideal + 2.5; rows += 2) {
    const columns = Math.ceil(n / rows)
    const empty = rows * columns - n
    const off = Math.abs(rows - ideal)
    if (!best || empty < best[2] || (empty === best[2] && off < best[3])) best = [rows, columns, empty, off]
  }
  return [best![0], best![1]]
}

/** `value` moved by whole periods into -period/2 ..< period/2. */
export const wrap = (value: number, period: number) => (period > 0 ? value - period * Math.round(value / period) : value)
