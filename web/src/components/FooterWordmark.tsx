// Footer wordmark: huge STASH in Stellost on the blue sky, dissolving into a progressive blur
// toward the bottom edge (stacked backdrop blurs, each masked to a later band).
const BLURS = [1, 2, 4, 8, 16, 32, 48]

export function FooterWordmark() {
  return (
    <div className="relative h-[24vw] max-h-[300px] min-h-[150px] w-full overflow-hidden border-t border-[#E8E8E5]">
      <div className="absolute inset-0 bg-[linear-gradient(180deg,#d6e7fb_0%,#8cb8f3_40%,#3f7ae6_80%,#1f57c9_100%)]" />
      <svg className="absolute inset-0 h-full w-full opacity-[0.3] mix-blend-overlay" aria-hidden>
        <filter id="footer-noise"><feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" stitchTiles="stitch" /><feColorMatrix type="saturate" values="0" /></filter>
        <rect width="100%" height="100%" filter="url(#footer-noise)" />
      </svg>
      <p
        className="absolute inset-x-0 top-[6%] select-none text-center font-['Stellost'] text-[29vw] leading-[0.85] text-white lg:text-[330px] [text-shadow:0_20px_60px_rgba(10,30,90,0.3)]"
        style={{ maskImage: 'linear-gradient(180deg,#000 35%,transparent 100%)', WebkitMaskImage: 'linear-gradient(180deg,#000 35%,transparent 100%)' }}
      >
        STASH
      </p>
      {BLURS.map((b, i) => {
        const from = 20 + i * 10
        const mask = `linear-gradient(180deg, transparent ${from}%, #000 ${from + 14}%)`
        return (
          <div
            key={b}
            className="pointer-events-none absolute inset-0"
            style={{ backdropFilter: `blur(${b}px)`, WebkitBackdropFilter: `blur(${b}px)`, maskImage: mask, WebkitMaskImage: mask }}
          />
        )
      })}
    </div>
  )
}
