// Production server: static files from dist/client, everything else to the TanStack Start handler.
import handler from './dist/server/server.js'

const root = `${import.meta.dir}/dist/client`

Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  async fetch(req) {
    const path = decodeURIComponent(new URL(req.url).pathname)
    if (path !== '/' && !path.includes('..')) {
      const file = Bun.file(root + path)
      if (await file.exists()) {
        // Vite fingerprints /assets; everything else can change between deploys.
        const cache = path.startsWith('/assets/') ? 'public, max-age=31536000, immutable' : 'public, max-age=3600'
        return serveFile(req, file, cache)
      }
    }
    return handler.fetch(req)
  },
})

// Range support: Safari will not play a <video> from a server that ignores Range.
function serveFile(req: Request, file: ReturnType<typeof Bun.file>, cache: string) {
  const headers = { 'Content-Type': file.type, 'Cache-Control': cache, 'Accept-Ranges': 'bytes' }
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.get('range') ?? '')
  if (!m) return new Response(file, { headers })
  const size = file.size
  const start = m[1] ? Number(m[1]) : Math.max(0, size - Number(m[2]))
  const end = m[1] && m[2] ? Math.min(Number(m[2]), size - 1) : size - 1
  if (start >= size || start > end) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } })
  return new Response(file.slice(start, end + 1), {
    status: 206,
    headers: { ...headers, 'Content-Range': `bytes ${start}-${end}/${size}`, 'Content-Length': String(end - start + 1) },
  })
}
