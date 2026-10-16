import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { posts, rank } from '#/data/posts'
import { globeLayout, wrap } from '#/lib/globeLayout'
import { PostCard } from './PostCard'

// Same geometry as the app's GlobeField: equal 4:3 cards on a sphere that repeats in four directions.
const CW = 260
const CH = 195
const PX = CW + 22
const PY = CH + 22
const COPIES = [-1, 0, 1]
const ENTER_MS = 950
const SUGGESTIONS = ['coffee', 'night sky', 'dog', 'tokyo', 'bread recipe', 'surf']

const instances = COPIES.flatMap((cy) => COPIES.flatMap((cx) => posts.map((_, i) => ({ i, cx, cy }))))
const clamp01 = (v: number) => Math.min(1, Math.max(0, v))
const easeOut = (t: number) => 1 - (1 - t) ** 3

type Props = {
  open: boolean
  from: DOMRect | null
  query: string
  setQuery: (q: string) => void
  onClose: (reason: 'scroll' | 'dismiss') => void
}

export function SearchMode({ open, from, query, setQuery, onClose }: Props) {
  const [mounted, setMounted] = useState(false)
  const barRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const stageRef = useRef<HTMLDivElement>(null)
  const sceneRef = useRef<HTMLDivElement>(null)
  const cards = useRef<(HTMLDivElement | null)[]>([])
  const ranked = useMemo(() => rank(query), [query])
  const n = posts.length
  const st = useRef({
    camX: 0, camY: 0, vx: 0, vy: 0, tiltX: 0, tiltY: 0,
    drag: null as null | { x: number; y: number; id: number; moved: number; type: string },
    cur: new Float64Array(n * 2), target: new Float64Array(n * 2), rankOf: new Array<number>(n).fill(0),
    shown: false, snap: true, enterStart: 0, exit: 0, periodX: 1, periodY: 1,
  })

  useEffect(() => { if (open) setMounted(true) }, [open])

  // Rank → cells. The first query builds the globe; later ones glide cards to their new cells.
  useEffect(() => {
    const s = st.current
    const layout = globeLayout(n, PX / PY)
    s.periodX = layout.columns * PX
    s.periodY = layout.rows * PY
    ranked.order.forEach((item, r) => {
      s.rankOf[item] = r
      s.target[item * 2] = layout.cells[r][0] * PX
      s.target[item * 2 + 1] = layout.cells[r][1] * PY
    })
    if (query.trim() && !s.shown) {
      s.shown = true
      s.snap = true
      s.enterStart = performance.now()
      s.exit = 0
    }
    if (s.snap) { s.cur.set(s.target); s.camX = 0; s.camY = 0; s.snap = false }
  }, [ranked, query, n])

  // Opening: the hero pill grows into the top bar, the input takes focus, entry replays.
  useLayoutEffect(() => {
    if (!open) return
    const s = st.current
    s.exit = 0
    s.enterStart = performance.now()
    inputRef.current?.focus({ preventScroll: true })
    const bar = barRef.current
    if (bar && from) {
      const to = bar.getBoundingClientRect()
      bar.animate(
        [
          { transform: `translate(${from.left - to.left}px, ${from.top - to.top}px) scale(${from.width / to.width})`, transformOrigin: 'top left' },
          { transform: 'none', transformOrigin: 'top left' },
        ],
        { duration: 560, easing: 'cubic-bezier(.2,.8,.2,1)' },
      )
    }
    const prev = document.documentElement.style.overflow
    document.documentElement.style.overflow = 'hidden'
    return () => { document.documentElement.style.overflow = prev }
  }, [open, from])

  // Frame loop: camera inertia, sphere mapping, entry from every direction, scroll-driven exit.
  useEffect(() => {
    if (!open || !mounted) return
    let raf = 0
    const frame = (t: number) => {
      raf = requestAnimationFrame(frame)
      const s = st.current
      const stage = stageRef.current
      if (!stage) return
      const w = stage.clientWidth
      const h = stage.clientHeight
      if (!s.drag) { s.camX += s.vx; s.camY += s.vy; s.vx *= 0.92; s.vy *= 0.92 }
      const R = Math.max(w, h) * 1.05
      const dist = Math.max(w, h) * 1.2
      sceneRef.current!.style.transform = `rotateX(${s.tiltY}deg) rotateY(${s.tiltX}deg)`
      for (let k = 0; k < n * 2; k++) s.cur[k] += (s.target[k] - s.cur[k]) * 0.12
      const dim = ranked.matched.size > 0
      instances.forEach(({ i, cx, cy }, idx) => {
        const el = cards.current[idx]
        if (!el) return
        const dx = wrap(s.cur[i * 2] - s.camX, s.periodX) + cx * s.periodX
        const dy = wrap(s.cur[i * 2 + 1] - s.camY, s.periodY) + cy * s.periodY
        const theta = dx / R
        const phi = dy / R
        if (!s.shown || Math.abs(theta) > 1.5 || Math.abs(phi) > 1.2) { el.style.display = 'none'; return }
        const r = s.rankOf[i]
        const delay = r * 16 + (cx || cy ? 240 : 0)
        const enter = easeOut(clamp01((t - s.enterStart - delay) / ENTER_MS))
        const out = clamp01(s.exit * 1.9 - (r / n) * 0.9) ** 2
        const away = Math.max(1 - enter, out)
        const len = Math.hypot(dx, dy)
        const a = r * 2.39996
        const ux = len > 1 ? dx / len : Math.cos(a)
        const uy = len > 1 ? dy / len : Math.sin(a)
        const x = R * Math.sin(theta) * Math.cos(phi) + ux * dist * away
        const y = R * Math.sin(phi) + uy * dist * away
        const z = R * (Math.cos(theta) * Math.cos(phi) - 1) + 700 * away
        el.style.display = 'block'
        el.style.opacity = String((1 - away * 0.95) * (!dim || ranked.matched.has(i) ? 1 : 0.22))
        el.style.transform = `translate3d(${x}px,${y}px,${z}px) rotateY(${theta}rad) rotateX(${-phi}rad) rotateZ(${ux * 30 * away}deg)`
      })
    }
    raf = requestAnimationFrame(frame)
    return () => cancelAnimationFrame(raf)
  }, [open, mounted, ranked, n])

  // Wheel and vertical swipes push the cards back out the way they came; at the end the page scrolls on.
  useEffect(() => {
    const stage = stageRef.current?.parentElement
    if (!open || !stage) return
    const push = (dy: number) => {
      const s = st.current
      if (!s.shown) { if (dy > 20) onClose('scroll'); return }
      s.exit = clamp01(s.exit + dy / 900)
      if (s.exit >= 1) onClose('scroll')
    }
    const wheel = (e: WheelEvent) => { e.preventDefault(); push(e.deltaY) }
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose('dismiss') }
    stage.addEventListener('wheel', wheel, { passive: false })
    window.addEventListener('keydown', key)
    const s = st.current
    const down = (e: PointerEvent) => {
      if ((e.target as HTMLElement).closest('[data-chrome]')) return
      s.drag = { x: e.clientX, y: e.clientY, id: e.pointerId, moved: 0, type: e.pointerType }
      s.vx = s.vy = 0
    }
    const move = (e: PointerEvent) => {
      const stg = stageRef.current
      if (stg) {
        s.tiltX = (e.clientX / stg.clientWidth - 0.5) * 4
        s.tiltY = -(e.clientY / stg.clientHeight - 0.5) * 4
      }
      const d = s.drag
      if (!d || d.id !== e.pointerId) return
      const mx = e.clientX - d.x
      const my = e.clientY - d.y
      d.x = e.clientX
      d.y = e.clientY
      d.moved += Math.abs(mx) + Math.abs(my)
      if (d.type === 'touch' && Math.abs(my) > Math.abs(mx) * 1.5) { push(-my * 2); return }
      s.camX -= mx; s.camY -= my; s.vx = -mx; s.vy = -my
    }
    const up = (e: PointerEvent) => {
      const d = s.drag
      if (!d || d.id !== e.pointerId) return
      s.drag = null
      if (d.moved < 4 && !query.trim() && !(e.target as HTMLElement).closest('[data-card]')) onClose('dismiss')
    }
    stage.addEventListener('pointerdown', down)
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    return () => {
      stage.removeEventListener('wheel', wheel)
      window.removeEventListener('keydown', key)
      stage.removeEventListener('pointerdown', down)
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
  }, [open, onClose, query])

  const count = ranked.matched.size
  return (
    <div
      className={`fixed inset-0 z-50 select-none transition-opacity duration-500 ${open ? 'opacity-100' : 'pointer-events-none opacity-0'}`}
      style={{ touchAction: 'none' }}
      aria-hidden={!open}
      inert={!open}
    >
      <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_50%_40%,#ffffff_0%,#f4f4f2_70%,#ececea_100%)]" />
      <div ref={stageRef} className="absolute inset-0 overflow-hidden [perspective:1500px]">
        <div ref={sceneRef} className="absolute left-1/2 top-[56%] transform-3d">
          {mounted &&
            instances.map(({ i }, idx) => (
              <div
                key={idx}
                data-card
                ref={(el) => { cards.current[idx] = el }}
                className="absolute will-change-transform"
                style={{ width: CW, height: CH, left: -CW / 2, top: -CH / 2, display: 'none' }}
              >
                <PostCard p={posts[i]} />
              </div>
            ))}
        </div>
      </div>
      <div className="pointer-events-none absolute inset-x-0 top-0 h-48 bg-linear-to-b from-white via-white/80 to-transparent" />

      <div data-chrome className="absolute left-1/2 top-8 flex w-[min(660px,calc(100%-32px))] -translate-x-1/2 flex-col items-center gap-3">
        <div ref={barRef} className="flex h-[68px] w-full items-center gap-3.5 rounded-full border border-[#E4E4E1] bg-white px-6 shadow-[0_24px_60px_-20px_rgba(0,0,0,0.35),0_2px_6px_rgba(0,0,0,0.06)]">
          <SearchIcon />
          <input
            ref={inputRef}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Describe what you remember…"
            className="min-w-0 flex-1 bg-transparent text-[19px] text-[#0A0A0A] outline-none placeholder:text-[#A1A1AA]"
            aria-label="Search the sample library"
          />
          <button onClick={() => onClose('dismiss')} className="rounded-md border border-[#E4E4E1] bg-[#FBFBFA] px-2.5 py-1 text-[12px] font-medium text-[#71717A]">
            esc
          </button>
        </div>
        {query.trim() ? (
          <div className="flex h-8 items-center gap-2 rounded-full border border-white/10 bg-[#0A0A0A]/80 px-4 backdrop-blur-md">
            <span className="h-1.5 w-1.5 rounded-full bg-[#22C55E]" />
            <span className="text-[12px] text-white/80">
              {count ? `${count} result${count === 1 ? '' : 's'} · on-device` : 'No match yet · showing everything'}
            </span>
          </div>
        ) : (
          <div className="flex flex-wrap justify-center gap-2">
            {SUGGESTIONS.map((s) => (
              <button key={s} onClick={() => setQuery(s)} className="h-8 rounded-full border border-[#E4E4E1] bg-white px-3.5 text-[13px] text-[#3F3F46] hover:border-[#0A0A0A]">
                {s}
              </button>
            ))}
          </div>
        )}
      </div>
      <p data-chrome className="pointer-events-none absolute bottom-6 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-white/85 px-3.5 py-1.5 text-[12px] text-[#52525B] shadow-sm backdrop-blur">
        Drag to spin · Scroll to continue · Esc to close
      </p>
    </div>
  )
}

export const SearchIcon = ({ className = 'h-5 w-5' }: { className?: string }) => (
  <svg className={`block shrink-0 fill-none stroke-[#0A0A0A] stroke-[1.67] [stroke-linecap:round] [stroke-linejoin:round] ${className}`} viewBox="0 0 20 20" aria-hidden>
    <path d="M17.5 17.5l-3.62-3.62M15.83 9.17a6.66 6.66 0 1 1-13.33 0 6.66 6.66 0 0 1 13.33 0Z" />
  </svg>
)
