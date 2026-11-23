// @ts-check
import { defineConfig, fontProviders } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { unified } from '@astrojs/markdown-remark';
import { loadEnv } from 'vite';
import { createHash } from 'node:crypto';
import { remarkOwnerNotes } from './src/lib/remark-owner-notes.mjs';
import { draftLegalPaths } from './src/lib/legal-status.mjs';
import { INLINE_SCRIPTS } from './src/lib/inline-scripts.mjs';
import { cspUnion } from './src/lib/csp-union.mjs';

const env = loadEnv(process.env.NODE_ENV ?? 'production', process.cwd(), 'PUBLIC_');
const API_BASE = (env.PUBLIC_API_BASE || 'https://api.hasala.app/api').replace(/\/+$/u, '');
const API_ORIGIN = new URL(API_BASE).origin;
const WAITLIST_MODE = env.PUBLIC_WAITLIST_MODE || 'api';
if (WAITLIST_MODE !== 'email' && WAITLIST_MODE !== 'api') {
  throw new Error(
    `PUBLIC_WAITLIST_MODE must be "email" or "api", not ${JSON.stringify(WAITLIST_MODE)}`,
  );
}
const TURNSTILE = WAITLIST_MODE === 'api' && Boolean(env.PUBLIC_TURNSTILE_SITEKEY);
const TURNSTILE_ORIGIN = 'https://challenges.cloudflare.com';
const CF_ANALYTICS_SCRIPT = 'https://static.cloudflareinsights.com';
const CF_ANALYTICS_REPORT = 'https://cloudflareinsights.com';

const NOT_IN_SITEMAP = [
  '/i',
  '/freeze',
  '/joined',
  '/waitlist/confirm',
  '/waitlist/leave',
  '/404',
  ...draftLegalPaths(new URL('../docs/legal/', import.meta.url)),
];

export default defineConfig({
  site: 'https://hasala.app',
  output: 'static',
  trailingSlash: 'never',
  build: {
    format: 'file',
    inlineStylesheets: 'always',
  },
  compressHTML: true,
  scopedStyleStrategy: 'class',
  markdown: { syntaxHighlight: false, processor: unified({ remarkPlugins: [remarkOwnerNotes] }) },
  prefetch: false,
  devToolbar: { enabled: false },
  integrations: [
    sitemap({
      filter: (page) =>
        !NOT_IN_SITEMAP.some((path) => new URL(page).pathname.replace(/\/$/u, '') === path),
    }),
    cspUnion({
      withoutAnalytics: {
        token: '%CSP_WITHOUT_ANALYTICS%',
        drop: [CF_ANALYTICS_SCRIPT, CF_ANALYTICS_REPORT],
      },
    }),
  ],
  fonts: [
    {
      name: 'Inter',
      cssVariable: '--font-inter',
      provider: fontProviders.local(),
      fallbacks: ['system-ui', 'sans-serif'],
      display: 'swap',
      options: {
        variants: [
          {
            src: ['./src/assets/fonts/inter-latin-opsz-wght.woff2'],
            weight: '100 900',
            style: 'normal',
          },
        ],
      },
    },
  ],
  security: {
    csp: {
      algorithm: 'SHA-256',
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "font-src 'self'",
        `connect-src 'self' ${API_ORIGIN} ${CF_ANALYTICS_REPORT}${TURNSTILE ? ` ${TURNSTILE_ORIGIN}` : ''}`,
        `form-action 'self'${WAITLIST_MODE === 'api' ? ` ${API_ORIGIN}` : ''}`,
        `frame-src ${TURNSTILE ? TURNSTILE_ORIGIN : "'none'"}`,
        "manifest-src 'self'",
        "worker-src 'none'",
        "object-src 'none'",
        "base-uri 'self'",
        'upgrade-insecure-requests',
      ],
      scriptDirective: {
        resources: ["'self'", CF_ANALYTICS_SCRIPT, ...(TURNSTILE ? [TURNSTILE_ORIGIN] : [])],
        hashes: INLINE_SCRIPTS.map(
          (script) =>
            /** @type {`sha256-${string}`} */ (
              `sha256-${createHash('sha256').update(script).digest('base64')}`
            ),
        ),
      },
      styleDirective: {
        resources: ["'self'"],
      },
    },
  },
});
