import { createFileRoute } from '@tanstack/react-router'
import { animate, createScope, splitText, stagger } from 'animejs'
import { useCallback, useEffect, useRef, useState } from 'react'
import { posts } from '#/data/posts'
import { SearchIcon, SearchMode } from '#/components/SearchMode'
import { FooterWordmark } from '#/components/FooterWordmark'

export const Route = createFileRoute('/')({ component: Landing })

const brand = (file: string) => <img src={`/brands/${file}.svg`} alt="" loading="lazy" className="h-5 w-5 opacity-75" />
const SOURCES: { name: string; icon: React.ReactNode }[] = [
  { name: 'X bookmarks', icon: brand('x') },
  { name: 'Chrome', icon: brand('googlechrome') },
  {
    name: 'Edge',
    icon: (
      <svg className="h-5 w-5 fill-none stroke-[#3F3F46] stroke-[1.6] [stroke-linecap:round]" viewBox="0 0 20 20" aria-hidden>
        <circle cx="10" cy="10" r="7.5" /><path d="M2.5 10h15M10 2.5c2.2 2.3 2.2 12.7 0 15M10 2.5c-2.2 2.3-2.2 12.7 0 15" />
      </svg>
    ),
  },
  { name: 'Brave', icon: brand('brave') },
  { name: 'Arc', icon: brand('arc') },
  { name: 'Opera', icon: brand('opera') },
  { name: 'Vivaldi', icon: brand('vivaldi') },
  {
    name: 'Screenshots',
    icon: (
      <span className="flex gap-1">
        {['⌃', '⇧', '4'].map((k) => (
          <kbd key={k} className="flex h-6 min-w-6 items-center justify-center rounded-[6px] border border-[#E4E4E1] bg-white px-1 font-sans text-[12px] text-[#3F3F46] shadow-[0_1.5px_0_#E4E4E1]">{k}</kbd>
        ))}
      </span>
    ),
  },
  {
    name: 'Notes',
    icon: (
      <svg className="h-5 w-5 fill-none stroke-[#3F3F46] stroke-[1.6] [stroke-linecap:round] [stroke-linejoin:round]" viewBox="0 0 20 20" aria-hidden>
        <path d="M17.5 7.5a2 2 0 0 0-.59-1.42l-3-3A2 2 0 0 0 12.5 2.5H4.17c-.92 0-1.67.75-1.67 1.67v11.66c0 .92.75 1.67 1.67 1.67h11.66c.92 0 1.67-.75 1.67-1.67ZM12.5 2.5v4.17c0 .46.37.83.83.83h4.17" />
      </svg>
    ),
  },
]

// Always the newest notarized DMG; the release workflow uploads it with this name.
const DOWNLOAD = 'https://github.com/mrtcmn/stash/releases/latest/download/Stash.dmg'
const CHANGELOG = 'https://github.com/mrtcmn/stash/releases'
const SOURCE = 'https://github.com/mrtcmn/stash'

function Landing() {
  const [open, setOpen] = useState(false)
  const [from, setFrom] = useState<DOMRect | null>(null)
  const [query, setQuery] = useState('')
  const pill = useRef<HTMLButtonElement>(null)
  const [onSky, setOnSky] = useState(true)
  useEffect(() => {
    const sky = document.getElementById('sky-top')
    const update = () => setOnSky(!!sky && sky.getBoundingClientRect().bottom > 64)
    update()
    addEventListener('scroll', update, { passive: true })
    return () => removeEventListener('scroll', update)
  }, [])

  const openSearch = useCallback(() => {
    setFrom(pill.current?.getBoundingClientRect() ?? null)
    setOpen(true)
  }, [])
  const close = useCallback((reason: 'scroll' | 'dismiss') => {
    setOpen(false)
    if (reason === 'scroll') document.getElementById('product')?.scrollIntoView({ behavior: 'smooth' })
  }, [])

  useEffect(() => {
    const q = new URLSearchParams(location.search).get('q')
    if (q !== null) { setQuery(q); openSearch() }
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const scope = createScope().add(() => {
      const words = [...document.querySelectorAll('[data-anim="headline"]')].flatMap(
        (el) => splitText(el as HTMLElement, { words: true, accessible: true, includeSpaces: false }).words,
      )
      animate(words, { translateY: { from: '110%', to: '0%' }, duration: 800, delay: stagger(70), ease: 'outCubic' })
      animate('[data-anim="pill"]', { opacity: { from: 0, to: 1 }, translateY: { from: 24, to: 0 }, duration: 600, delay: 500, ease: 'outCubic' })
      animate('[data-anim="caret"]', { opacity: { from: 1, to: 0 }, duration: 600, ease: 'inOutQuad', loop: true, alternate: true })
    })
    return () => scope.revert()
  }, [openSearch])

  return (
    <div className="flex min-h-full w-full flex-col items-center overflow-x-clip bg-[#FBFBFA] text-[#0A0A0A]">
      <SearchMode open={open} from={from} query={query} setQuery={setQuery} onClose={close} />

      <header className={`sticky top-0 z-40 flex w-full justify-center border-b backdrop-blur-md transition-colors duration-300 ${onSky ? 'border-white/15 bg-white/5 text-white' : 'border-[#E8E8E5] bg-[#FBFBFA]/85'}`}>
        <div className={`flex h-16 w-full max-w-[1120px] items-center justify-between border-x px-6 ${onSky ? 'border-white/15' : 'border-[#E8E8E5]'}`}>
          <a href="#" aria-label="Stash">
            {/* White wordmark; inverted to black once the header leaves the sky. */}
            <img src="/wordmark.webp" alt="Stash" width={83} height={22} className={`h-[22px] w-auto transition-[filter] duration-300 ${onSky ? '' : 'invert'}`} />
          </a>
          <nav className={`hidden items-center gap-8 text-[14px] md:flex ${onSky ? 'text-white/80' : 'text-[#52525B]'}`}>
            <a href="#product">Product</a>
            <a href="#how">How it works</a>
            <a href="/privacy.html">Privacy</a>
            <a href="#pricing">Pricing</a>
            <a href={CHANGELOG}>Changelog</a>
          </nav>
          <a href={DOWNLOAD} className={`inline-flex h-9 items-center gap-2 rounded-full px-4 ${onSky ? 'bg-white text-[#0A0A0A]' : 'bg-[#0A0A0A] text-white'}`}>
            <AppleIcon className="h-4 w-4 -mt-0.5" />
            <span className="text-[14px] font-medium">Download</span>
          </a>
        </div>
      </header>

      <div id="sky-top" className="relative -mt-16 w-full overflow-hidden pt-16 text-white">
      <Sky />
      {/* Hero */}
      <section className="relative mx-auto flex w-full max-w-[1120px] flex-col items-center border-x border-white/15 px-4 pt-20">
        <a href="#how" className="inline-flex h-8 items-center gap-2.5 rounded-full border border-white/30 bg-white/15 pl-1.5 pr-3.5 backdrop-blur-md">
          <span className="inline-flex h-5 items-center rounded-full bg-white px-2 text-[11px] font-medium text-[#0A0A0A]">New</span>
          <span className="text-[13px] text-white/90">Semantic search now runs on WebGPU</span>
          <Arrow />
        </a>
        <h1 data-anim="headline" className="mt-7 text-center [text-shadow:0_2px_30px_rgba(10,30,90,0.25)] text-[52px] font-medium leading-[0.98] tracking-[-0.03em] md:text-[88px]">
          Save anything.
          <br />
          <span className="text-white/60">Find it by </span>
          <span className="font-['Instrument_Serif'] font-normal italic tracking-[-0.01em]">meaning.</span>
        </h1>
        <p className="mt-7 max-w-[540px] text-center text-[19px] leading-[1.55] text-white/80">
          Every post, page and screenshot you keep, in one library on your Mac. Describe what you remember and Stash finds it.
        </p>
        <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
          <a href={DOWNLOAD} className="inline-flex h-12 items-center gap-2.5 rounded-full bg-white px-6 text-[#0A0A0A] shadow-[0_8px_24px_-8px_rgba(10,30,80,0.5)]">
            <AppleIcon className="h-[18px] w-[18px] -mt-0.5" />
            <span className="text-[15px] font-medium">Download for Mac</span>
          </a>
          <button onClick={openSearch} className="inline-flex h-12 items-center gap-2.5 rounded-full border border-white/35 bg-white/15 px-6 backdrop-blur-md">
            <SearchIcon className="h-4 w-4 stroke-white!" />
            <span className="text-[15px] font-medium">Try the search here</span>
          </button>
        </div>
        <p className="mt-5 text-[13px] text-white/60">macOS 26+ · Apple Silicon · Free</p>

      </section>

      {/* Screen view: the app window in a glass frame over the same grainy sky. */}
      <section className="relative w-full text-[#0A0A0A]">
        <div className="relative mx-auto w-full max-w-[1180px] px-4 pt-20 md:px-10">
          <button
            ref={pill}
            data-anim="pill"
            onClick={openSearch}
            onFocus={openSearch}
            className="relative z-10 mx-auto mb-10 flex h-[68px] w-[min(660px,100%)] items-center gap-3.5 rounded-full border border-white/70 bg-white px-6 text-left shadow-[0_24px_60px_-20px_rgba(10,30,80,0.45),0_2px_6px_rgba(0,0,0,0.06)]"
          >
            <SearchIcon />
            <span className="truncate text-[19px]">{query || 'that latte with the heart in a blue cup'}</span>
            <span data-anim="caret" className="h-6 w-[2px] rounded-full bg-[#0A0A0A]" />
            <span className="flex-1" />
            <span className="hidden h-7 items-center rounded-md border border-[#E4E4E1] bg-[#FBFBFA] px-2.5 text-[12px] font-medium text-[#71717A] sm:inline-flex">⌘ K</span>
          </button>

          <div className="rounded-[28px] border border-white/60 bg-white/20 p-2.5 shadow-[0_50px_120px_-40px_rgba(10,30,80,0.6),inset_0_1px_0_rgba(255,255,255,0.7)] backdrop-blur-xl">
            <video
              ref={(v) => { if (v && matchMedia('(prefers-reduced-motion: reduce)').matches) v.pause() }}
              autoPlay
              muted
              loop
              playsInline
              poster="/hero-poster.webp"
              aria-label="The Stash library: saved posts on the globe view, with filters and search by meaning"
              className="block aspect-[1920/1230] w-full rounded-[20px] bg-black ring-1 ring-black/40"
              width={1920}
              height={1230}
            >
              <source src="/hero-mobile.mp4" type="video/mp4" media="(max-width: 767px)" />
              <source src="/hero.mp4" type="video/mp4" />
            </video>
          </div>
        </div>
        <div className="pointer-events-none absolute inset-x-0 bottom-0 h-72 bg-linear-to-b from-[#fbfbfa]/0 via-[#fbfbfa]/80 to-[#fbfbfa]" />
      </section>
      </div>

      <section id="product" className="relative grid w-full max-w-[1120px] scroll-mt-16 grid-cols-1 border-x border-t border-[#E8E8E5] md:grid-cols-3">
        <Corners />
        <Feature n="01 · Globe view" text="Every snip on one sphere. Spin it, filter it, fall into it." />
        <Feature n="02 · Instant filters" text="Posts, screenshots, notes and links — one keystroke apart." border />
        <Feature n="03 · EmbeddingGemma" text="A local model reads what you save. Nothing leaves the Mac." border />
      </section>

      <section className="relative w-full max-w-[1120px] border-x border-t border-[#E8E8E5]">
        <Corners />
        <p className="px-10 pb-6 pt-8 text-center text-[13px] text-[#71717A]">Pulls from the places good ideas already live — X, every Chromium browser, your screen</p>
        <div className="grid grid-cols-3 border-t border-[#E8E8E5] md:grid-cols-9">
          {SOURCES.map(({ name, icon }, i) => (
            <div key={name} className={`flex h-[96px] flex-col items-center justify-center gap-2 border-[#E8E8E5] text-[13px] font-medium text-[#3F3F46] ${i % 3 ? 'border-l' : ''} ${i >= 3 ? 'border-t md:border-t-0' : ''} ${i % 3 === 0 && i ? 'md:border-l' : ''}`}>
              {icon}
              {name}
            </div>
          ))}
        </div>
      </section>

      <section id="how" className="relative w-full max-w-[1120px] scroll-mt-16 border-x border-t border-[#E8E8E5]">
        <Corners />
        <div className="grid grid-cols-1 gap-10 px-10 pb-16 pt-24 md:grid-cols-2">
          <div className="flex flex-col gap-5">
            <Eyebrow>[ 01 ] How it works</Eyebrow>
            <h2 className="text-[48px] font-medium leading-[1.05] tracking-[-0.02em]">Your second brain,<br />without the filing.</h2>
          </div>
          <p className="self-end text-[17px] leading-[1.6] text-[#52525B]">Folders and tags take work, so most bookmarks never get looked at again. Stash reads each snip as you save it, so the thing you half-remember turns up in milliseconds.</p>
        </div>
        <div className="grid grid-cols-1 border-t border-[#E8E8E5] md:grid-cols-3">
          <Step title="Capture in one keystroke" text="Save a post, a page or a region of your screen from anywhere. X bookmarks sync on their own.">
            <div className="flex h-[180px] items-center justify-center gap-2.5 rounded-[14px] border border-[#E8E8E5] bg-white">
              <Key>⌃</Key><Key>⇧</Key><Key dark>4</Key>
            </div>
          </Step>
          <Step border title="Search by meaning" text="Describe it the way you remember it. Ranked results in about 2 ms, even with no exact keyword.">
            <div className="flex h-[180px] flex-col gap-3 rounded-[14px] border border-[#E8E8E5] bg-white p-4">
              <div className="flex h-9 items-center gap-2 rounded-full border border-[#E4E4E1] px-3"><SearchIcon className="h-3.5 w-3.5" /><span className="text-[13px]">latte with a heart</span></div>
              <Bar label="Blue cup" pct={71} color="#0A0A0A" />
              <Bar label="Cappuccino" pct={54} color="#A1A1AA" />
              <Bar label="Bakery" pct={38} color="#D4D4D8" />
            </div>
          </Step>
          <Step border title="Private by default" text="Embeddings run locally on Apple Silicon. Your library stays yours — no account needed.">
            <div className="flex h-[180px] flex-col items-center justify-center gap-4 rounded-[14px] border border-[#E8E8E5] bg-white">
              <div className="flex h-14 w-14 items-center justify-center rounded-full border border-[#E4E4E1]"><LockIcon /></div>
              <div className="inline-flex h-7 items-center gap-2 rounded-full bg-[#F4F4F2] px-3"><span className="h-1.5 w-1.5 rounded-full bg-[#16A34A]" /><span className="text-[12px] font-medium text-[#3F3F46]">On-device · no account</span></div>
            </div>
          </Step>
        </div>
      </section>

      <section className="relative flex w-full max-w-[1120px] flex-col border-x border-t border-[#E8E8E5] lg:flex-row">
        <Corners />
        <div className="flex shrink-0 items-center justify-center border-[#E8E8E5] p-6 lg:w-[720px] lg:border-r lg:p-10">
          <Reader />
        </div>
        <div className="flex min-w-0 flex-1 flex-col">
          <div className="flex flex-col gap-5 px-10 pb-10 pt-14">
            <Eyebrow>[ 02 ] The reader</Eyebrow>
            <h2 className="text-[32px] font-medium leading-[1.12] tracking-[-0.02em]">Every snip opens exactly as you saved it.</h2>
          </div>
          <Point n="01" lead="Full-fidelity posts." text="Media, threads and replies, archived even if the original gets deleted." />
          <Point n="02" lead="Arrow through results." text="← → moves through every match without losing your place." />
          <Point n="03" lead="Share back out." text="Post, copy or open the source in one click." />
        </div>
      </section>

      {/* TODO(owner): placeholder numbers from the design — replace with real ones before launch. */}
      <section className="relative grid w-full max-w-[1120px] grid-cols-2 border-x border-t border-[#E8E8E5] md:grid-cols-4">
        <Corners />
        <Stat v="2 ms" l="Median search time" />
        <Stat v="0 bytes" l="Sent to a server" border />
        <Stat v="1.2M" l="Snips saved in beta" border />
        <Stat v="4.9★" l="From early users" border />
      </section>

      {/* TODO(owner): placeholder testimonials from the design — swap in real quotes with permission. */}
      <section className="relative w-full max-w-[1120px] border-x border-t border-[#E8E8E5]">
        <Corners />
        <div className="flex flex-col items-center gap-5 px-10 pb-14 pt-24">
          <Eyebrow>[ 03 ] Loved by collectors</Eyebrow>
          <h2 className="max-w-[640px] text-center text-[48px] font-medium leading-[1.05] tracking-[-0.02em]">People who save a lot finally find it again.</h2>
        </div>
        <div className="grid grid-cols-1 border-t border-[#E8E8E5] md:grid-cols-3">
          <Quote q="I typed ‘that onboarding with the orange blob’ and it found a post from eight months ago. That's when I deleted my bookmarks folder." i="LK" n="Lena Kraus" r="Product designer" />
          <Quote border q="Local embeddings that are actually fast. It's the first tool of its kind I'd trust with my whole research trail." i="DO" n="Daniel Okafor" r="ML engineer" />
          <Quote border q="The globe view is unreasonably good. I open it just to wander through what I've collected." i="MS" n="Mira Santos" r="Founder, Loop Studio" />
        </div>
      </section>

      <section id="pricing" className="relative w-full max-w-[1120px] scroll-mt-16 border-x border-t border-[#E8E8E5]">
        <Corners />
        <div className="grid grid-cols-1 gap-10 px-10 pb-14 pt-24 md:grid-cols-2">
          <div className="flex flex-col gap-5">
            <Eyebrow>[ 04 ] Pricing</Eyebrow>
            <h2 className="text-[48px] font-medium leading-[1.05] tracking-[-0.02em]">Free. All of it.</h2>
          </div>
          <p className="self-end text-[17px] leading-[1.6] text-[#52525B]">The Mac app and the browser extension are free, with no snip limit and no account. Cloud sync and mobile apps are on the way.</p>
        </div>
        <div className="grid grid-cols-1 border-t border-[#E8E8E5] md:grid-cols-3">
          <Plan dark badge="Available now" name="Mac + extension" price="Free" sub="Everything, on your Mac" cta="Download for Mac" items={['Unlimited snips', 'Search by meaning, on-device', 'Globe view and filters', 'X bookmark import and sync']} />
          <Plan border soon badge="Coming soon" name="Cloud" price="Soon" sub="Your library on every device" cta="Coming soon" items={['End-to-end encrypted sync', 'Backups you control', 'Search across devices']} />
          <Plan border soon badge="Coming soon" name="Mobile" price="Soon" sub="iPhone and iPad" cta="Coming soon" items={['Save from the share sheet', 'The same search by meaning', 'Works offline']} />
        </div>
      </section>

      <section className="relative flex w-full max-w-[1120px] flex-col border-x border-t border-[#E8E8E5] md:flex-row">
        <Corners />
        <div className="flex shrink-0 flex-col gap-5 border-[#E8E8E5] px-10 pb-10 pt-24 md:w-[400px] md:border-r">
          <Eyebrow>[ 05 ] FAQ</Eyebrow>
          <h2 className="text-[40px] font-medium leading-[1.08] tracking-[-0.02em]">Questions, answered.</h2>
          <p className="text-[15px] leading-[1.6] text-[#71717A]">Something else? Open an issue on <a className="text-[#0A0A0A] underline" href={SOURCE}>GitHub</a>.</p>
        </div>
        <div className="flex min-w-0 flex-1 flex-col py-14">
          <Faq open q="Does anything I save leave my Mac?" a="No. Indexing and search run on your Mac with EmbeddingGemma on WebGPU. The app downloads the model once; your snips are never uploaded." />
          <Faq q="How does X bookmark sync work?" a="The browser extension scrolls your bookmarks once, then only picks up new ones. Bookmarking a post on X also saves it to Stash." />
          <Faq q="Can I import from Raindrop or Pocket?" a="Import files from the app's Import menu; dedicated importers are on the list." />
          <Faq q="Which Macs are supported?" a="Apple Silicon Macs running macOS 26 or later." />
          <Faq last q="Is there an iPhone app?" a="Coming soon, together with optional cloud sync. The Mac app and the browser extension come first." />
        </div>
      </section>

      <section className="relative flex w-full max-w-[1120px] flex-col items-center border-x border-t border-[#E8E8E5] px-10 py-28">
        <Corners />
        <img src="/icon-128.png" alt="" loading="lazy" className="h-[72px] w-[72px] rounded-[17px] shadow-[0_20px_40px_-14px_rgba(0,0,0,0.5)]" />
        <h2 className="mt-10 text-center text-[44px] font-medium leading-[1.02] tracking-[-0.02em] md:text-[64px]">Stop losing the good stuff.</h2>
        <p className="mt-5 text-[18px] text-[#71717A]">Free download. No account, no limits.</p>
        <div className="mt-10 flex flex-wrap items-center justify-center gap-3">
          <a href={DOWNLOAD} className="inline-flex h-12 items-center gap-2.5 rounded-full bg-[#0A0A0A] px-6 text-white shadow-[0_8px_24px_-8px_rgba(0,0,0,0.45)]">
            <AppleIcon className="h-[18px] w-[18px] -mt-0.5" />
            <span className="text-[15px] font-medium text-white">Download for Mac</span>
          </a>
          <a href={SOURCE} className="inline-flex h-12 items-center gap-2 rounded-full border border-[#E4E4E1] bg-white px-6">
            <span className="text-[15px] font-medium">Read the changelog</span>
            <Arrow up />
          </a>
        </div>
      </section>

      <footer className="flex w-full justify-center border-t border-[#E8E8E5]">
        <div className="relative w-full max-w-[1120px] overflow-hidden border-x border-[#E8E8E5]">
          <div className="grid grid-cols-2 gap-6 px-10 py-14 md:grid-cols-5">
            <div className="col-span-2 flex flex-col gap-4">
              <div className="flex items-center gap-2.5">
                <img src="/icon-128.png" alt="" loading="lazy" className="h-7 w-7 rounded-[7px]" />
                <span className="text-[17px] font-semibold tracking-[-0.01em]">Stash</span>
              </div>
              <p className="max-w-[260px] text-[14px] leading-[1.6] text-[#71717A]">A quiet library for everything worth keeping.</p>
            </div>
            <FooterCol t="Product" l={[['Features', '#product'], ['Pricing', '#pricing'], ['Changelog', CHANGELOG]]} />
            <FooterCol t="Company" l={[['Privacy', '/privacy.html'], ['Source', SOURCE]]} />
            <FooterCol t="Follow" l={[['GitHub', SOURCE]]} />
          </div>
          <div className="flex items-center justify-between border-t border-[#E8E8E5] px-10 py-5">
            <span className="text-[13px] text-[#71717A]">© 2026 Stash</span>
            <span className="text-[13px] text-[#71717A]">Sample posts are fictional · photos from Pexels</span>
          </div>
          <FooterWordmark />
        </div>
      </footer>
    </div>
  )
}

/** Grainy sky: layered blues, soft cloud masses, SVG fractal noise on top. */
function Sky() {
  return (
    <div className="pointer-events-none absolute inset-0" aria-hidden>
      <div className="absolute inset-0 bg-[linear-gradient(180deg,#1f57c9_0%,#2d6ce0_28%,#4f8ae9_52%,#8cb8f3_76%,#d6e7fb_100%)]" />
      {/* Clouds stay at the edges and low, so the white headline keeps its contrast. */}
      <div className="absolute -left-[18%] top-[16%] h-[30%] w-[42%] -rotate-12 rounded-full bg-white/45 blur-[100px]" />
      <div className="absolute -right-[16%] top-[8%] h-[26%] w-[40%] rotate-12 rounded-full bg-white/35 blur-[110px]" />
      <div className="absolute -left-[10%] top-[52%] h-[30%] w-[60%] -rotate-6 rounded-full bg-white/50 blur-[100px]" />
      <div className="absolute -right-[8%] top-[60%] h-[28%] w-[50%] rotate-6 rounded-full bg-white/45 blur-[110px]" />
      <div className="absolute left-[25%] top-[2%] h-[22%] w-[50%] rounded-full bg-[#1a4fbf]/60 blur-[90px]" />
      <svg className="absolute inset-0 h-full w-full opacity-[0.35] mix-blend-overlay">
        <filter id="sky-noise"><feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" stitchTiles="stitch" /><feColorMatrix type="saturate" values="0" /></filter>
        <rect width="100%" height="100%" filter="url(#sky-noise)" />
      </svg>
    </div>
  )
}

function Reader() {
  const p = posts[1]
  return (
    <div className="w-full max-w-[640px] rounded-[16px] bg-[#0B0B0C] p-1.5 shadow-[0_0_0_1px_rgba(0,0,0,0.06),0_30px_60px_-28px_rgba(0,0,0,0.45)]">
      <div className="relative aspect-[16/10] overflow-hidden rounded-[11px]">
        <img src="/reader.webp" alt="" loading="lazy" className="absolute inset-0 h-full w-full scale-110 object-cover blur-2xl brightness-50" />
        <div className="absolute inset-x-[12%] top-[10%] bottom-0 rounded-t-[18px] bg-[#1c1c1e]/90 p-5 ring-1 ring-white/10">
          <div className="flex items-center gap-2.5">
            <div className="flex h-9 w-9 items-center justify-center rounded-full bg-white/15 text-[12px] font-semibold text-white">NH</div>
            <div className="leading-tight"><p className="text-[14px] font-semibold text-white">{p.name}</p><p className="text-[12px] text-white/55">@{p.handle} · {p.date}</p></div>
          </div>
          <p className="mt-3 text-[15px] text-white/90">{p.text}</p>
          <img src="/reader.webp" alt="" loading="lazy" className="mt-3 h-full w-full rounded-[12px] object-cover" />
        </div>
      </div>
    </div>
  )
}

const PlusIcon = ({ className }: { className: string }) => (
  <svg className={`pointer-events-none absolute block h-4 w-4 fill-none stroke-[#A1A1AA] stroke-[1.33] [stroke-linecap:round] ${className}`} viewBox="0 0 16 16" aria-hidden>
    <path d="M3.33 8h9.34M8 3.33v9.34" />
  </svg>
)
const Corners = () => (<><PlusIcon className="-left-2 -top-2" /><PlusIcon className="-right-2 -top-2" /></>)
const Eyebrow = ({ children }: { children: React.ReactNode }) => <p className="text-[12px] font-medium uppercase tracking-wider text-[#71717A]">{children}</p>
const b = (on?: boolean) => (on ? 'border-[#E8E8E5] md:border-l' : '')

const Feature = ({ n, text, border }: { n: string; text: string; border?: boolean }) => (
  <div className={`flex flex-col gap-1.5 px-10 py-8 ${b(border)}`}><Eyebrow>{n}</Eyebrow><p className="text-[15px] leading-[1.5] text-[#3F3F46]">{text}</p></div>
)
const Step = ({ title, text, border, children }: { title: string; text: string; border?: boolean; children: React.ReactNode }) => (
  <div className={`flex flex-col gap-8 p-10 ${b(border)}`}>
    {children}
    <div className="flex flex-col gap-2"><h3 className="text-[19px] font-medium tracking-[-0.01em]">{title}</h3><p className="text-[15px] leading-[1.6] text-[#71717A]">{text}</p></div>
  </div>
)
const Key = ({ children, dark }: { children: React.ReactNode; dark?: boolean }) => (
  <div className={`flex h-14 w-14 items-center justify-center rounded-[12px] text-[20px] ${dark ? 'bg-[#0A0A0A] font-medium text-white shadow-[0_2px_0_#3F3F46]' : 'border border-[#E4E4E1] bg-[#FBFBFA] text-[#3F3F46] shadow-[0_2px_0_#E4E4E1]'}`}>{children}</div>
)
const Bar = ({ label, pct, color }: { label: string; pct: number; color: string }) => (
  <div className="flex items-center gap-3">
    <span className="w-20 text-[12px] text-[#3F3F46]">{label}</span>
    <div className="h-1.5 flex-1 rounded-full bg-[#F1F1EF]"><div className="h-1.5 rounded-full" style={{ width: `${pct}%`, background: color }} /></div>
    <span className="text-[11px] tabular-nums text-[#71717A]">{pct}%</span>
  </div>
)
const Point = ({ n, lead, text }: { n: string; lead: string; text: string }) => (
  <div className="flex gap-5 border-t border-[#E8E8E5] px-10 py-5">
    <span className="text-[13px] tabular-nums text-[#71717A]">{n}</span>
    <p className="text-[15px] leading-[1.55] text-[#3F3F46]"><span className="font-medium text-[#0A0A0A]">{lead}</span> {text}</p>
  </div>
)
const Stat = ({ v, l, border }: { v: string; l: string; border?: boolean }) => (
  <div className={`flex flex-col gap-2 px-10 py-12 ${b(border)}`}><p className="text-[44px] font-medium leading-none tracking-[-0.02em] tabular-nums">{v}</p><p className="text-[14px] text-[#71717A]">{l}</p></div>
)
const Quote = ({ q, i, n, r, border }: { q: string; i: string; n: string; r: string; border?: boolean }) => (
  <figure className={`flex flex-col justify-between gap-10 p-10 ${b(border)}`}>
    <p className="text-[17px] leading-[1.6] text-[#27272A]">“{q}”</p>
    <div className="flex items-center gap-3">
      <div className="flex h-9 w-9 items-center justify-center rounded-full bg-[#E4E4E1] text-[13px] font-medium text-[#3F3F46]">{i}</div>
      <div className="flex flex-col"><span className="text-[14px] font-medium">{n}</span><span className="text-[13px] text-[#71717A]">{r}</span></div>
    </div>
  </figure>
)
const Check = ({ dark }: { dark?: boolean }) => (
  <svg className={`h-4 w-4 fill-none stroke-[1.33] [stroke-linecap:round] [stroke-linejoin:round] ${dark ? 'stroke-white' : 'stroke-[#0A0A0A]'}`} viewBox="0 0 16 16" aria-hidden><path d="M13.33 4 6 11.33 2.67 8" /></svg>
)
const Plan = ({ name, price, sub, cta, items, badge, dark, soon, border }: { name: string; price: string; sub: string; cta: string; items: string[]; badge: string; dark?: boolean; soon?: boolean; border?: boolean }) => (
  <div className={`flex flex-col gap-8 p-10 ${dark ? 'bg-[#0A0A0A] text-white' : ''} ${b(border)}`}>
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-3">
        <p className="text-[15px] font-medium">{name}</p>
        <span className={`inline-flex h-6 shrink-0 items-center rounded-full px-2.5 text-[11px] font-medium uppercase tracking-wider ${dark ? 'bg-white/10 text-white/80' : 'border border-dashed border-[#D4D4D8] text-[#71717A]'}`}>{badge}</span>
      </div>
      <p className={`text-[44px] font-medium leading-none tracking-[-0.02em] ${soon ? 'text-[#71717A]' : ''}`}>{price}</p>
      <p className={`text-[14px] ${dark ? 'text-white/50' : 'text-[#71717A]'}`}>{sub}</p>
    </div>
    {soon ? (
      <span className="inline-flex h-11 cursor-default items-center justify-center rounded-full border border-dashed border-[#D4D4D8] text-[14px] font-medium text-[#71717A]">{cta}</span>
    ) : (
      <a href={DOWNLOAD} className="inline-flex h-11 items-center justify-center rounded-full bg-white text-[14px] font-medium text-[#0A0A0A]">{cta}</a>
    )}
    <div className={`flex flex-col gap-3 border-t pt-6 ${dark ? 'border-white/10' : 'border-[#E8E8E5]'}`}>
      {items.map((t) => (
        <div key={t} className={`flex items-center gap-2.5 ${soon ? 'opacity-80' : ''}`}><Check dark={dark} /><span className={`text-[14px] ${dark ? 'text-white/80' : 'text-[#3F3F46]'}`}>{t}</span></div>
      ))}
    </div>
  </div>
)
const Faq = ({ q, a, open, last }: { q: string; a: string; open?: boolean; last?: boolean }) => (
  <details open={open} className={`group border-t border-[#E8E8E5] px-10 py-6 ${last ? 'border-b' : ''}`}>
    <summary className="flex cursor-pointer list-none items-center justify-between text-[17px] font-medium">
      {q}
      <svg className="h-4 w-4 fill-none stroke-[#71717A] stroke-[1.33] [stroke-linecap:round] group-open:stroke-[#0A0A0A]" viewBox="0 0 16 16" aria-hidden>
        <path d="M3.33 8h9.34" /><path className="group-open:hidden" d="M8 3.33v9.34" />
      </svg>
    </summary>
    <p className="mt-3 max-w-[560px] text-[15px] leading-[1.6] text-[#71717A]">{a}</p>
  </details>
)
const FooterCol = ({ t, l }: { t: string; l: [string, string][] }) => (
  <div className="flex flex-col gap-3">
    <p className="text-[13px] font-medium">{t}</p>
    {l.map(([label, href]) => <a key={label} href={href} className="text-[14px] text-[#71717A] hover:text-[#0A0A0A]">{label}</a>)}
  </div>
)
const Arrow = ({ up }: { up?: boolean }) => (
  <svg className="h-3.5 w-3.5 fill-none stroke-[#71717A] stroke-[1.2] [stroke-linecap:round] [stroke-linejoin:round]" viewBox="0 0 14 14" aria-hidden>
    <path d={up ? 'M4 4h6v6M4 10l6-6' : 'M2.92 7h8.16M7 2.92 11.08 7 7 11.08'} />
  </svg>
)
const AppleIcon = ({ className }: { className: string }) => (
  <svg className={`fill-current ${className}`} viewBox="0 0 24 24" aria-hidden>
    <path d="M12.15 6.9c-.95 0-2.42-1.08-3.96-1.04-2.04.03-3.91 1.18-4.96 3.01-2.12 3.68-.55 9.1 1.52 12.09 1.01 1.45 2.2 3.09 3.79 3.04 1.52-.07 2.09-.99 3.93-.99 1.83 0 2.35.99 3.96.95 1.64-.03 2.68-1.48 3.68-2.95 1.15-1.69 1.63-3.33 1.66-3.42-.04-.01-3.18-1.22-3.22-4.86-.03-3.04 2.48-4.49 2.6-4.56-1.43-2.09-3.63-2.32-4.39-2.38-2-.15-3.68 1.09-4.61 1.09ZM15.53 3.83c.84-1.01 1.4-2.43 1.25-3.83-1.21.05-2.67.8-3.53 1.82-.78.9-1.46 2.34-1.27 3.71 1.33.1 2.71-.69 3.55-1.7Z" />
  </svg>
)
const LockIcon = () => (
  <svg className="h-5 w-5 fill-none stroke-[#0A0A0A] stroke-[1.67] [stroke-linecap:round] [stroke-linejoin:round]" viewBox="0 0 20 20" aria-hidden>
    <rect x="2.5" y="9.17" width="15" height="9.16" rx="2" /><path d="M5.83 9.17V5.83a4.17 4.17 0 0 1 8.34 0v3.34" />
  </svg>
)
