# Design — Poof

A locked design system for this app. Every page redesign reads this file before
emitting code. Do not regenerate per page. Extend or amend this file when the
system needs to grow.

## Genre

editorial

## Macrostructure family

- Marketing / home: Index-First. The board is the page. No centred hero, no
  display headline above the fold.
- App pages: Workbench. Functional headings, hairline rules, the list or form
  carries the page. No enrichment.
- Content pages: Long Document. Changelog reads as release notes, not cards.

## Theme

Newsprint. Warm paper, oxblood accent, roman display.

- `--color-paper`   oklch(92% 0.045 50)
- `--color-paper-2` oklch(89% 0.050 50)
- `--color-ink`     oklch(15% 0.030 25)
- `--color-ink-2`   oklch(20% 0.030 28)
- `--color-rule`    oklch(68% 0.030 40)
- `--color-accent`  oklch(32% 0.10 28)
- `--color-focus`   oklch(48% 0.18 30)

## Typography

- Display: Newsreader, weight 700, style normal
- Body: IBM Plex Sans, weight 400
- Mono: IBM Plex Mono, weight 400 (code fences only)
- Display tracking: -0.022em
- Type scale anchor: `--text-display` = clamp(2rem, 3vw + 1rem, 2.875rem)

Home does not use display type. Interior pages use `--text-display-s` for page
titles so long issue titles stay readable.

## Spacing

4-point named scale. The values are in `tokens.css`. Pages must use named
tokens (`var(--space-md)`), never raw values.

## Motion

- Easings: `--ease-out` cubic-bezier(0.16, 1, 0.3, 1), `--ease-in`
  cubic-bezier(0.7, 0, 0.84, 0), `--ease-in-out` cubic-bezier(0.65, 0, 0.35, 1)
- Reveal pattern: none
- Hover: 1px translateY on buttons only
- Reduced-motion fallback: opacity-only, ≤ 150 ms

## Microinteractions stance

- silent success, never celebratory toasts
- hover delay 800 ms · focus delay 0 ms
- focus rings appear instantly, never animate in

## CTA voice

- Primary CTA: ink fill, square corners, 14px IBM Plex Sans 500. Verb names
  the action (`New feedback`, `Post comment`, `Save`).
- Secondary CTA: hairline border, paper fill, same padding rhythm.

## Per-page allowances

- Marketing pages MAY use enrichment (Tier-A CSS art, Tier-B SVG). Home does
  not: the index is the product.
- App pages MUST NOT use enrichment.
- Content pages: typography only.

## What pages MUST share

- The wordmark set in Newsreader.
- The oxblood accent at ≤ 5 % of any viewport (links, active nav, focus, bug
  labels).
- Newsreader + IBM Plex Sans + IBM Plex Mono.
- Square CTA voice (radius 0, ink primary, hairline secondary).
- Stacked section heads. No hanging left-margin labels.

## What pages MAY differ on

- Macrostructure within the page-type family.
- Hero archetype on marketing pages only. Home stays Index-First.
- Enrichment on marketing pages only, Tier-A or Tier-B.

## Nav and footer

- Nav: N6 newspaper masthead. Small caps ledger line, centred wordmark,
  double rule, then a single bar of destinations plus the session action.
- Footer: Ft4 dense colophon. One block of credits, then the MCP tokens link.

## Exports

See `tokens.css` at the project root.
