import { HeadContent, Scripts, createRootRoute } from '@tanstack/react-router'

import appCss from '../styles.css?url'

// TODO(owner): set to the production domain. og:image and canonical need an absolute URL.
const SITE = 'https://stash.app'
const TITLE = 'Stash — Save anything. Find it by meaning.'
const DESCRIPTION = 'Every post, page and screenshot you keep, in one library on your Mac. Search by meaning, on-device.'

const jsonLd = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: 'Stash',
  description: DESCRIPTION,
  url: SITE,
  image: `${SITE}/og.jpg`,
  applicationCategory: 'ProductivityApplication',
  operatingSystem: 'macOS 26',
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
}

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { title: TITLE },
      { name: 'description', content: DESCRIPTION },
      { name: 'theme-color', content: '#FBFBFA' },
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: 'Stash' },
      { property: 'og:url', content: SITE },
      { property: 'og:title', content: TITLE },
      { property: 'og:description', content: DESCRIPTION },
      { property: 'og:image', content: `${SITE}/og.jpg` },
      { property: 'og:image:width', content: '1200' },
      { property: 'og:image:height', content: '630' },
      { property: 'og:image:alt', content: 'Stash' },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: TITLE },
      { name: 'twitter:description', content: DESCRIPTION },
      { name: 'twitter:image', content: `${SITE}/og.jpg` },
    ],
    links: [
      { rel: 'canonical', href: SITE },
      { rel: 'icon', href: '/icon-128.png' },
      { rel: 'apple-touch-icon', href: '/icon-128.png' },
      { rel: 'preload', as: 'image', href: '/hero-poster.webp', fetchPriority: 'high' },
      { rel: 'preload', as: 'font', type: 'font/woff2', href: '/fonts/instrument-serif-italic-latin.woff2', crossOrigin: 'anonymous' },
      { rel: 'stylesheet', href: appCss },
    ],
  }),
  shellComponent: RootDocument,
})

function RootDocument({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
