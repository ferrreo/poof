# Design — Poof

A locked design system for this app. Every page redesign reads this file before
emitting code. Do not regenerate per page. Extend or amend this file when the
system needs to grow.

## Genre

modern-minimal

## Macrostructure family

- Marketing / home: Index-First. The board is the page. No centred hero, no
  display headline above the fold.
- App pages: Workbench. Functional headings, sticky tools, the list or form
  carries the page. No enrichment.
- Content pages: Long Document. Changelog reads as release notes, not cards.

## Theme

Studied DNA from https://pika-os.com, dark surfaces from
https://builder.pika-os.com. Warm paper yellows in light. Dark paper is
chroma-0 charcoal (`#161616` / `#1f1f1f`), not hue-96 brown. Amber (hue 96)
is accent and CTA only. Primary CTA is ink fill with amber text in light,
amber fill with dark text in dark (builder sidebar chip).

- `--color-paper`   light-dark(oklch(97.5% 0.015 96), oklch(20% 0 0))
- `--color-paper-2` light-dark(oklch(95.5% 0.018 96), oklch(24% 0 0))
- `--color-paper-3` light-dark(oklch(93% 0.022 96), oklch(30% 0 0))
- `--color-ink`     light-dark(oklch(26% 0.012 96), oklch(91% 0 0))
- `--color-ink-2`   light-dark(oklch(32% 0.012 96), oklch(78% 0 0))
- `--color-rule`    light-dark(oklch(82% 0.014 96), oklch(34% 0 0))
- `--color-accent`  light-dark(oklch(90.2% 0.173 96.7), oklch(88% 0.17 96))
- `--color-focus`   light-dark(oklch(72% 0.16 96.7), oklch(88% 0.17 96))
- `--color-primary-fill` / `--color-primary-text` for CTA (do not invert `--color-ink`)

## Typography

- Display: Ubuntu Sans, weight 700, style normal
- Body: Ubuntu Sans, weight 400
- Mono: JetBrains Mono, weight 400 (code fences and admin labels)
- Display tracking: -0.02em
- Type scale anchor: `--text-display` = clamp(2rem, 3vw + 1rem, 2.875rem)

Home does not use display type. Interior pages use `--text-display` for page
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

- Primary CTA: ink fill + amber text in light; amber fill + dark text in dark.
  Small radius, 14px Ubuntu Sans 600. Verb names the action (`New feedback`,
  `Post comment`, `Save`).
- Secondary CTA: 1px edge border, paper fill, same padding rhythm.

## Per-page allowances

- Marketing pages MAY use enrichment (Tier-A CSS art, Tier-B SVG). Home does
  not: the index is the product.
- App pages MUST NOT use enrichment.
- Content pages: typography only.

## What pages MUST share

- Site title (and optional logo) from admin branding settings.
- Amber accent at ≤ 8 % of any viewport (active nav underline, focus, primary
  CTA text).
- Color scheme follows `prefers-color-scheme` unless the visitor pins Light or
  Dark via the header control (`poof_theme` cookie, `data-theme` on `<html>`).
  Light paper stays hue 96. Dark paper is chroma 0 charcoal, matching
  builder. Hue 96 is accent/CTA only in dark.
- Ubuntu Sans + JetBrains Mono.
- Compact CTA voice (radius-sm, ink primary with accent text, bordered secondary).
- Stacked section heads. No hanging left-margin labels.

## What pages MAY differ on

- Macrostructure within the page-type family.
- Hero archetype on marketing pages only. Home stays Index-First.
- Enrichment on marketing pages only, Tier-A or Tier-B.

## Nav and footer

- Nav: N1b sticky slab. Brand left, destinations plus session action on the
  right, heavy bottom border.
- Footer: Ft2 compact colophon. Credits line, then the MCP tokens link.

## Exports

See `tokens.css` at the project root.
