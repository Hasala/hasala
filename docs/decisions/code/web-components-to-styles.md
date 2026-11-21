# Website components, pages, scripts and styles: decisions from the code (2026-11-21)

These decisions were code comments under `web/src/components/`, `web/src/data/`,
`web/src/layouts/`, `web/src/lib/`, `web/src/pages/`, `web/src/scripts/` and
`web/src/styles/`. Code comments are not permitted (`scripts/comment-lint.ts`), thus the
decisions are here.

The rules that keep Web Analytics off the pages with a code or a token, the two waitlist
modes and the status of the legal pages are in `CLAUDE.md` ("Website"). They are not
repeated here.

## Email links carry the token in the fragment and act only on a button press

The links in our emails are `https://hasala.app/freeze#<token>`,
`https://hasala.app/waitlist/confirm#<token>` and `https://hasala.app/waitlist/leave#<token>`.
The token is 43 base64url characters in the fragment. No request carries a fragment, thus
the token never reaches a server log or a proxy log.

The page asks for nothing. Its script reads the token, removes it from the address bar and
shows one button. Only a press of that button sends `{token}` to the API. A mail link
scanner or a link preview only does a GET of the page and never presses the button, thus a
scanner cannot freeze an account, confirm an address or leave the list for a person.

The freeze button sends a simple CORS request (`text/plain`, no credentials, no referrer),
so the page can read the status with no preflight. Only a 204 shows the done state. The
server answers 204 for each token, valid or not
(`docs/decisions/code/server-api-2.md`, "One answer where a difference tells a secret").
Thus the done state must not say more than "if this link was valid".

Do not move a token into the path or the query. Do not send the request when the page
loads. Do not change the done text to say that an account is frozen. The first puts the
token in logs, the second lets a scanner act, and the third tells a caller which tokens
are live.

Applies to: `web/src/pages/freeze.astro`, `web/src/components/FreezeDone.astro`,
`web/src/components/WaitlistLink.astro`, `web/src/lib/freeze.ts` (`postFreeze`).

## The invite page reads the code in the browser and never calls the API

`hasala.app/i/<code>` is one static page for all codes: `public/_redirects` rewrites
`/i/*` to `/i`. The invite email links to `/i/<CODE>#<LINK_KEY>`. A script reads the code
from the path and the link key from the fragment, then removes them from the address bar
and from the history entry. The older form `/i#<CODE>` is still read. On an iPhone with
Hasala installed, the universal link opens the app and the page is not shown.

The page can show the code, but it never calls the API and it sends no referrer. Thus the
page cannot know when an invite expires, and it shows no date. Do not add an expiry date or
a "code is valid" state: each needs a request that carries the code.

With no code (a reload after the code left the address bar, no JavaScript, the nav's "Have
a code?"), the same page shows "Have an invite code?". The inline script `INVITE_CODE`
chooses the view before the first paint, and the page script removes the class when the
value is not a code.

Applies to: `web/src/pages/i.astro`, `web/src/lib/inline-scripts.mjs` (`INVITE_CODE`).

## Waitlist form: what a request sends and what the page says

In "api" mode the form is a real form. Without JavaScript it posts to the API, and the API
answers with a 303 to `HASALA_WEB_WAITLIST_DONE_URL`. That server setting must be
`https://hasala.app/joined`. A validation error comes back as `/joined?error=<code>`.

Each valid submission gets the same answer, when the address is new and when it is on the
list already (`docs/decisions/code/server-api-2.md`). Thus the page shows one card for all
of them: "Check your email", with the step to confirm within 7 days. "You're on the list"
is only for `/waitlist/confirm`, after the confirm link works. Do not show a different
text for an address that is on the list.

In "email" mode nothing is posted. The fields get no `name` attribute (`named()` gives
`undefined`), so a form post without JavaScript carries no data and only opens `/joined`.
For that reason the script finds the fields by id, not by name. This mode has no
confirmation step. The address that we add is the address that the email comes from, not
the address typed in the form, and the copy says so.

Applies to: `web/src/components/WaitlistForm.astro`, `web/src/scripts/waitlist.ts`,
`web/src/pages/joined.astro`.

## One Content-Security-Policy for every page

Astro writes one CSP `<meta>` for each page, with the hashes of the inline scripts and
styles of that page only. With `<ClientRouter />`, a client-side navigation puts the
`<head>` of the next page into the same document. A document enforces each CSP that it was
given. After `/` then `/privacy`, the styles of `/privacy` must also pass the policy of
`/`, and the browser blocks them. Astro also does not hash the `<style>` that it writes
for `transition:name`.

Thus, after the build, `csp-union.mjs` does these steps:

1. It merges the `script-src` and the `style-src` of all pages.
2. It adds the hash of each inline script and style in the output.
3. It writes that one policy into each page.
4. It marks the `<meta>` with `transition:persist`, so the router keeps the one that the
   document has and does not add copies.

The build fails if two pages disagree on a different directive. `scripts/router.ts` loads a
page in full when the fetched page has a different policy (a deployment during a visit).

With `withoutAnalytics`, the same step fills in `dist/_headers`: each token there becomes
the final `script-src` and `connect-src` without the Web Analytics sources. The build
fails if `_headers` has no such token.

Do not give a page its own policy, and do not remove the `transition:persist` mark. The
styles or scripts of the second page of a visit are then blocked, and only a client-side
navigation shows the fault.

Applies to: `web/src/lib/csp-union.mjs`, `web/src/scripts/router.ts`.

## Inline scripts are fixed strings in one file

The site runs only the inline scripts in `INLINE_SCRIPTS`. They are in `<head>` because
they must apply before the first paint, and a bundled module cannot do that.
`astro.config.mjs` puts the hash of these exact strings into the `script-src` of each
page.

Keep each inline script as a string in `inline-scripts.mjs`, and render it with
`set:html`. An inline script that is written in a page, or a string that a template
changes, has a different hash, and the browser does not run it.

Applies to: `web/src/lib/inline-scripts.mjs`, `web/src/layouts/Base.astro`.

## Client-side navigation: per-page setup, kept classes and history state

A bundled module runs one time for each full load, but `<ClientRouter />` changes pages
with no reload. Thus each per-page setup goes through `onPage()`. It runs immediately and
again after each swap. Its `AbortSignal` fires when the page is swapped out. Give the
signal to each `addEventListener` and use it to disconnect each observer. If a script does
its setup at module level, it does not run on the second page, and its listeners stay on
elements that are gone.

On a swap the router gives `<html>` the attributes of the new page. This removes the
classes that the `<head>` scripts added on the first load, and a head script that ran is
not run again. Thus `router.ts` puts these classes on the new document before the swap:

- `js`: the no-JS fallbacks stay hidden.
- `hero-seen`: the hero entrance still plays one time for each tab session.
- `routed`: the page came by a client-side navigation, so the first-load entrances (the
  invite tile on `/i`) stay still.
- `vt-swap`: scroll is instant while the router puts the new page at the top, at its
  fragment or at the restored position. A smooth scroll below the cross-fade looks like a
  fault. The class is removed after the scripts of the new page have run.

The router keeps its data in `history.state`. A page script that calls
`history.replaceState` must pass `history.state`, not `null`. If not, Back and Forward
stop working correctly.

Applies to: `web/src/scripts/page.ts` (`onPage`), `web/src/scripts/router.ts`,
`web/src/pages/[doc].astro`, `web/src/pages/i.astro`.

## Turnstile under the client router

Turnstile's `api.js` loads one time for each document. The router makes `<head>` again on
each client-side navigation and removes the tag. Thus `loadTurnstile` adds an empty
placeholder with the same `transition:persist` id to each new document, and Astro keeps
our tag in its position. `data-astro-exec` tells the router that the tag has run, so the
router does not insert it and run it again.

The widget is rendered explicitly, not automatically. An automatic widget does not show
after a client-side navigation. The render gives the action that the server checks
(`waitlist` or `bank_request`).

A Turnstile token is for one use. Call `reset` after each attempt, also after a failed
one. A second attempt with the same token is refused. A build with no site key has no
widget: `check` answers `off` and `reset` does nothing.

Applies to: `web/src/scripts/api.ts` (`loadTurnstile`, `renderTurnstile`).

## The site header is kept across pages and lets taps through

The header has `transition:persist` for each variant. The router keeps it and does not
render it again between pages of the same variant. Thus its markup must be the same on all
those pages. The mark of the current page is not in the markup: `nav.ts` sets it for each
page, and resets the header state for each page.

The bar and the lockup have view-transition names, so they stay still while the page fades
below them. The name is on `.nav`, the element that has the `backdrop-filter`. On a
different element, the frost does not blur the page.

The router replaces the classes of `<html>` on a swap and has already scrolled the new
page to its position. Thus `nav.ts` sets the frost class again on `astro:after-swap`, so
the frost is correct before the new page shows.

`.site-nav` has `pointer-events: none`, so taps go through to the page. The open menu sets
`pointer-events: auto`. Without it, a tap on a menu link goes through to the backdrop and
only closes the menu.

Applies to: `web/src/components/Nav.astro`, `web/src/scripts/nav.ts`.

## Screen edges on iOS Safari

Safari on iOS cannot show a gradient or an image behind the status bar or its toolbar. It
shows only a solid colour. For the status bar it uses the background colour of the
document: the colour of `body` if `body` has one, else the colour of `html`. It can also
extend fixed strips at the screen edges behind its controls.

Thus:

- Each full-bleed block declares the solid colour of its top edge and its bottom edge
  (`--edge-t`, `--edge-b`; white when not set). The `--edge-*` colours are the end stops of
  the washes as solid colours.
- The background of `html` is `--edge-top`. `scripts/edges.ts` sets it, the strips
  (`.edge-top`, `.edge-bottom`) and the `theme-color` meta from the blocks below the screen
  edges, one time for each frame on scroll and on resize, and after each page load. The
  colours change in one step, with no animation.
- `body` paints white as an image (`linear-gradient` of one colour), not as a background
  colour. A background colour on `body` is the colour that Safari shows behind the status
  bar, and it hides the colour of `html`. The navy page (`/how-privacy-works`) paints its
  navy on `body` as an image for the same reason.
- Without JavaScript, the edges keep the top colour of the page (`html[data-edge]`, from
  the `edge` property of `Base`) and white. The same colours are in two places: `EDGE` in
  `Base.astro` (for the `theme-color` meta) and `--edge-*` in `global.css`. Change them
  together.
- `edges.ts` lets the browser mix the two declared colours (`color-mix`). It does not
  parse colours. Thus each colour syntax works, also the short forms that the CSS minifier
  writes.
- The strips have the height of the safe-area insets only, with no minimum of 12px. In
  iOS 27 Safari the layout viewport ends at the status bar and above the toolbar. A 12px
  strip there hid 12px of the page (a line of text above the toolbar) and did not change
  the colour behind the controls.

Do not give `body` a background colour, and do not give the strips a minimum height.

Applies to: `web/src/styles/global.css` (`--edge-*`, `.edge-top`, `.edge-bottom`, `body`),
`web/src/scripts/edges.ts`, `web/src/layouts/Base.astro` (`EDGE`),
`web/src/pages/how-privacy-works.astro`.

## Motion: it ends within 5 seconds and always has a still version

These rules apply to all motion on the site (Paper "13 · Dynamic layer"):

- Nothing loops, and nothing moves while a person reads text.
- Motion that starts by itself ends within 5 seconds (WCAG 2.2.2). The idle float of the
  hero and of the phone is one move up and one move back (1.3 s, two iterations, after
  2.4 s). The tokens of the privacy flow move one time each. The demo of the review deck
  plays one time, in less than 5 seconds, and stops permanently on hover, focus, a hidden
  tab or an interaction.
- Each motion has a still version. With reduced motion, the page shows its final state.
- A hidden start state applies only while JavaScript runs (`.js`) and motion is permitted
  (`prefers-reduced-motion: no-preference`). Thus the page is complete without JavaScript
  and without motion.

If you change a duration, a delay or an iteration count, calculate the end time again. If
you add a hidden start state outside these two conditions, content stays hidden for a
person without JavaScript.

Applies to: `web/src/scripts/motion.ts`, `web/src/scripts/review.ts`,
`web/src/styles/global.css` (`[data-reveal]`), `web/src/components/HomePhone.astro`,
`web/src/components/sections/Hero.astro`, `web/src/components/detail/PrivacyFlow.astro`.

## Reveals start in the footer, once for each document

The top of the footer is a `[data-reveal]` element, and it is hidden until the reveals
start. Thus the footer calls `initMotion()` on each page, also on the pages with no
sections of their own (the legal pages, `/how-privacy-works`). Do not remove that call:
the footer then stays hidden on those pages.

The pages with sections call `initMotion()` too. It registers with `onPage` only one time
for each document. `onPage` runs it again after each client-side navigation, so a second
registration runs it two times.

Applies to: `web/src/components/Footer.astro`, `web/src/scripts/motion.ts` (`initMotion`).

## A script never resets or animates what is already on screen

A script can arrive late, and a page can arrive with content on screen (a deep link, a
restored scroll position, a client-side navigation). In these cases nothing that the
person sees must go back to a start state.

- Reveals: an element that is in view when the script runs gets `is-in` with no
  transition. The hidden state applies from the first paint, so the script measures first.
  Then it adds `reveal-instant` (transitions off), adds `is-in`, forces one style flush and
  removes `reveal-instant`. Keep this sequence: read, then write, then flush, then remove.
  Without the flush, the browser joins the changes and the transition runs.
- `is-scrolled-in` marks only an element that came into view while the script watched it.
  A keyframe moment that plays one time (the invite coin) uses this class, so it does not
  play on content that was on screen when the page arrived.
- The pace card is armed (set to zero) only when it starts out of view.
- The figure of `HomePhone` counts on the clock of the bar's CSS animation. If the script
  arrives after the 300 ms delay of that animation, it leaves the figure as it is.

Applies to: `web/src/scripts/motion.ts` (`reveals`, `pace`),
`web/src/components/HomePhone.astro`.

## HomePhone: the entrance plays only while its keyframe names exist

The entrance of `HomePhone` is pure CSS. Each rule is `animation: var(--hp-…) …`. The
custom properties `--hp-rise`, `--hp-wipe`, `--hp-drop`, `--hp-fade` and `--hp-draw` hold
the keyframe names, and they are set only while the entrance must play (the `play` mode,
motion permitted). `--hp-idle` is set when motion is permitted. When a property is not
set, its `animation` declaration is invalid, nothing moves, and the screen shows its final
state. The script reads `--hp-rise` to know if the entrance plays.

`play="hero"` plays one time for each tab session (`html.hero-seen`). `play="load"` plays
one time for each full page load, not after a client-side navigation (`html.routed`).

Do not give these properties a value at `:root` or a fallback in `var()`. The entrance
then plays on each navigation and with reduced motion.

Applies to: `web/src/components/HomePhone.astro`.

## Entrances: no fade on the hero phone, and one property for each movement

The hero stage does not animate `opacity`. The phone is the largest paint of the page, and
a fade from zero delays the largest contentful paint. Lighthouse must stay at 0.9 or more
for performance.

Movements that occur on the same element use different CSS properties, so one does not
replace the other:

- The hero stage enters with `translate`. Its `transform` holds the `scale(.8)` below 1280
  and the parallax.
- A hero float enters with `transform`, floats with `translate` and has its tilt in
  `rotate`.
- The waitlist coin settles with `translate`. Its focus lift uses `transform`.

If two of these movements use the same property, the later animation removes the scale, the
tilt or the lift while it runs.

The coin settles only when the form scrolls into view on the home page
(`.is-scrolled-in`), not on `/joined` or the confirm pages.

Applies to: `web/src/components/sections/Hero.astro`, `web/src/components/sections/Beta.astro`.

## Easing inside @keyframes is a literal curve

An `animation-timing-function` inside `@keyframes` is written as
`cubic-bezier(0.65, 0, 0.35, 1)`, the value of `--ease-in-out`. `var()` is not read
there. If you put `var(--ease-in-out)` in a keyframe, that step loses its easing. When
`--ease-in-out` changes, change these literals too.

Applies to: `web/src/styles/global.css`, `web/src/components/sections/Beta.astro`.

## Fit figures: one line that shrinks with its card

A large money line (unit and number) stays on one line and shrinks with its card. It does
not wrap and does not overflow. This is CSS only:

- `.fig-box` goes on the card, or on a block whose width does not depend on its content.
  It becomes the size container.
- `.fig-fit` goes on the line. The unit and the gaps are sized in em, so the full line
  scales together.
- `--fig-max` is the design size. `--fig-k` is the width of the full line in em, measured
  in the widest figure font (Inter or SF Pro Rounded), plus approximately 4% slack.
  `--fig-fixed` is the part of the line that does not scale, in px.
- The font size is `min(--fig-max, (container width - --fig-fixed) / --fig-k)`.

Do not set `font-size` on the `.fig-fit` element in a scoped style. A scoped selector has
priority over the global rule, and the line stops shrinking. Size the children in em.

When the text of a figure changes, measure `--fig-k` again. The values in use:

| Figure | Measurement | `--fig-k` | `--fig-fixed` |
| --- | --- | --- | --- |
| Spending and Everyday pace figure | number 4.82em, unit 0.1667em, plus slack | 5.35 | 40px (the 12.67px part of the unit, plus the gap) |
| Bill amount | 40px number, 18px unit, 6px gap, 17px "every month", all in em | 4.65 | 40px (the side padding of the card head) |
| Plan bucket percentage | "50%" is 2.11em; at most approximately 26% of the card on a phone | 3.9 | 0 |

Applies to: `web/src/styles/global.css` (`.fig-box`, `.fig-fit`),
`web/src/components/sections/Spending.astro`, `web/src/components/detail/Everyday.astro`,
`web/src/components/sections/BillsFound.astro`, `web/src/components/sections/PlanSplit.astro`.

## Review deck: the exit time of a dragged card depends on its curve

A dragged card leaves from the position where the finger released it, at the speed of the
finger. The exit curve for a drag is `cubic-bezier(.3,.6,.4,1)`, which starts at 2 times
its average speed. Thus the duration is `2 × distance / release speed`, limited to 180 ms
to 320 ms. With this value the card continues at the speed of the flick, with no sudden
change. The demo starts from rest and uses a different curve that accelerates.

The factor 2 belongs to that curve. If you change the curve, calculate the factor again
from its start slope.

Applies to: `web/src/scripts/review.ts` (`swipe`).

## Legal pages: lenient front matter schema

The Markdown of the legal pages is in `docs/legal/`, outside the web package. The persons
who own the wording write it, and the site only renders it. The collection schema lets
unknown keys through on purpose. A new field in the Markdown must not stop the build, and
a build stop here is a stop of each deployment. Do not make the schema strict.

Applies to: `web/src/content.config.ts`.

## Legal pages: a heading keeps its own accessible name

The script adds a "Copy link" button inside each heading of a legal page. It first puts
the text of the heading in a `<span>` and sets `aria-labelledby` on the heading to that
span. Without it, a screen reader adds the label of the button ("Copy link to …") to the
name of the heading.

Applies to: `web/src/pages/[doc].astro`.

## Licences page: what is listed and which text is shown

`THIRD_PARTY` lists only the third-party software that the built site sends to the
browser: the font in `src/assets/fonts/` and the code in `dist/_astro/*.js`
(`V=1 bun scripts/check-dist.ts` lists the files of each page). Tools that operate only
during the build (the Astro compiler, sharp, the sitemap integration) send nothing and are
not in the list. `NOTICE` must say the same.

`/licenses` shows the licence file of each package unchanged where the build can read it
(the OFL of Inter, the `LICENSE` of Astro and of uqr). Vite is the exception. Its
`LICENSE.md` also contains the licences of all that Vite bundles into its own build, and
none of that reaches the site. Thus the entry of Vite is the MIT License with the
copyright line of Vite only.

The licence files are imported by relative paths into `node_modules`, because the export
maps of the packages do not list their `LICENSE` files.

Applies to: `web/src/data/licenses.ts`, `web/src/pages/licenses.astro`.

## Site facts: a new mail service changes more than the list

The site says "your email" in all places. Only `MAIL`, `MAIL_PERSONAL` and `MAIL_NOTE`
name the services, and they come from `MAIL_PROVIDERS`. When you add a mail service, also
change the trademark line in the footer and the legal pages (`docs/legal`). "Outlook"
means personal Microsoft accounts only, and `MAIL_NOTE` says so
(`docs/decisions/outlook-mailbox.md`).

Applies to: `web/src/data/site.ts` (`MAIL_PROVIDERS`).

## The site says source-available, never open source

The source is available under FSL-1.1-ALv2. That licence is not an open-source licence
until a version becomes Apache-2.0. The copy of the site must say "source-available" and
must not say "open source".

Applies to: `web/src/data/site.ts` (`SITE.repoUrl`, `SITE.licenseUrl`).

## The suggested banks use the slugs and names of the server catalog

`OTHER_BANKS` are the banks that people frequently ask for. The "Which one?" field of the
invite form suggests their names. Each `value` is the slug of that bank in the server
catalog (table `banks`), and each `name` is the name in the catalog. Thus a name that a
person picks agrees with the catalog entry and its aliases, and the request counts for that
bank. A different spelling here makes a request for an unknown bank.

Applies to: `web/src/data/site.ts` (`OTHER_BANKS`).

## The website is light only

The site sets `color-scheme: light`. The Paper design has no dark version of the site: the
privacy section is navy in the light design already. Do not add `dark` to the colour
scheme before a dark design exists. The browser then draws dark form controls and scroll
bars on the light pages.

Applies to: `web/src/styles/global.css` (`:root`), `web/src/layouts/Base.astro`.
