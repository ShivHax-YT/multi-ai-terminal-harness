# Harness design tokens

Source of truth for colors, radii, motion and type. Implemented in `src/styles/globals.css` (`:root` light, `.dark`,
Tailwind `@theme inline`). `src/styles/tokens.test.ts` parses the table below, checks every value against
`globals.css`, and recomputes every contrast ratio (WCAG 2.x relative luminance), so this file and the CSS cannot drift.

Graphite neutrals plus one accent, orchid (hue 322°). Accent = shadcn `--primary`; shadcn `--accent` stays a neutral
hover surface. No blue, teal-green or clay-orange anywhere (rule 8). Status is never color alone: always an icon plus a
text label.

## Colors

| Token | Light | Dark | Contrast (light / dark) |
|---|---|---|---|
| --background / --card, --popover | #F7F7F8 / #FFFFFF | #111114 / #18181C | |
| --muted, --secondary, --accent / --border | #EFEFF1 / #DCDCE0 | #222228 / #2E2E36 | border decorative |
| --input | #8E8E99 | #6B6B78 | 3.2 / 3.4 vs card |
| --foreground / --muted-foreground | #17171B / #5B5B66 | #ECECF1 / #A1A1AD | 16.7 / 16.0; 6.3 / 7.4 vs bg (5.8 / 6.2 vs muted) |
| --primary, --ring (orchid, hue 322°) | #9C1F6E | #F08BC8 | 6.9 / 8.3 vs bg; on-primary #FFFFFF 7.4 / #17171B 7.9 |
| --success (olive 86°) / --warning (ochre 39°) | #3F6212 / #8A5A00 | #A3C76A / #D8B35E | 6.6 / 9.8; 5.5 / 9.5 vs bg |
| --destructive (crimson 353°) | #B42335 | #FF8F8F | 6.1 / 8.6 vs bg; on-it #FFFFFF 6.5 / #17171B 8.2 |
| --terminal-bg / --terminal-fg (both themes) | #0E0E11 / #E4E4EA | same | 15.2 |

Derived tokens (no new colors): `--card-foreground`, `--popover-foreground`, `--secondary-foreground`,
`--accent-foreground` = `--foreground`; `--primary-foreground` and `--destructive-foreground` = the "on" colors above;
sidebar: `--sidebar` = `--muted` (light) / `--card` (dark), `--sidebar-accent` = `--card` (light) / `--muted` (dark),
`--sidebar-primary`, `--sidebar-ring` = `--primary`, `--sidebar-border` = `--border`.

## Radius

| Use | Value | Tailwind |
|---|---|---|
| Cards, dialogs' outer surface | 14px (`--radius-card`) | `rounded-xl` |
| Controls (inputs, buttons, menus) | 10px (`--radius-control`) | `rounded-md`, `rounded-lg` |
| Chips and badges | 9999px (`--radius-chip`) | `rounded-full` |

## Motion

| Token | Value | Use |
|---|---|---|
| `--duration-fast` | 150ms | hover, press |
| `--duration-base` | 220ms | panel and tab switches (Transition Panel, at most 250ms) |
| `--duration-slow` | 300ms | staggers (Animated Group, 40ms step) |
| `--duration-entrance` | 600ms | one-time entrances (In View) |
| `--ease-out` | cubic-bezier(.16,1,.3,1) | every entrance |

Only transform and opacity animate. Text Shimmer (background-position) is the one exception and waits for the
human's OK; until then `Shimmer` renders an opacity pulse. Every wrapper in `src/components/motion/` renders static
content under `prefers-reduced-motion`, and the root uses `MotionConfig reducedMotion="user"`.

## Type

| Use | Font | Size / line height |
|---|---|---|
| UI and body | Inter Variable (`@fontsource-variable/inter`) | 16px / 1.55 |
| Small text | Inter Variable | 14px; 12px for labels only |
| Headings | Inter Variable, semibold | 24 / 20 / 16px |
| Terminals, diffs, logs, paths, hashes | JetBrains Mono Variable (`@fontsource-variable/jetbrains-mono`) | 13px / 1.5 |

Fonts are bundled; there is no runtime network fetch (rule 5, strict CSP).
