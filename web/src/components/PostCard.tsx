import type { Post } from '#/data/posts'

const XMark = () => (
  <svg viewBox="0 0 24 24" className="h-3.5 w-3.5 fill-white/80" aria-hidden>
    <path d="M17.75 3h3.07l-6.7 7.66L22 21h-6.17l-4.83-6.32L5.47 21H2.4l7.17-8.2L2 3h6.33l4.37 5.77L17.75 3Zm-1.08 16.17h1.7L7.4 4.73H5.58l11.09 14.44Z" />
  </svg>
)

function Author({ p }: { p: Post }) {
  return (
    <div className="flex items-center gap-2">
      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-white/15 text-[11px] font-semibold text-white ring-1 ring-white/20">
        {p.name.split(' ').map((w) => w[0]).join('')}
      </div>
      <div className="min-w-0 leading-tight">
        <p className="truncate text-[12.5px] font-semibold text-white">{p.name}</p>
        <p className="truncate text-[11.5px] text-white/60">@{p.handle} · {p.date}</p>
      </div>
    </div>
  )
}

/** The app's 4:3 tile: full-bleed media with the author over a scrim, or text on graphite. */
export function PostCard({ p }: { p: Post }) {
  return (
    <div className="relative h-full w-full overflow-hidden rounded-[20px] bg-[#151515] shadow-[0_28px_60px_-28px_rgba(0,0,0,0.65)] ring-1 ring-black/10 transition-transform duration-300 hover:scale-[1.035]">
      {p.image ? (
        <>
          <img src={p.image} alt="" draggable={false} className="absolute inset-0 h-full w-full object-cover" />
          <div className="absolute inset-0 bg-linear-to-t from-black/85 via-black/25 to-transparent" />
          <div className="absolute right-3.5 top-3.5"><XMark /></div>
          <div className="absolute inset-x-4 bottom-3.5">
            <Author p={p} />
            <p className="mt-2 line-clamp-2 text-[13px] leading-snug text-white">{p.text}</p>
          </div>
        </>
      ) : (
        <div className="flex h-full flex-col gap-3 p-4">
          <div className="flex items-start justify-between"><Author p={p} /><XMark /></div>
          <p className="line-clamp-5 text-[15px] leading-snug text-white/90">{p.text}</p>
        </div>
      )}
    </div>
  )
}
