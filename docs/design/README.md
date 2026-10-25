# Harness design approach

Applies to every Phase 1 UI brief (T-101..T-110). The concrete tokens and their contrast ratios are proposed in
`docs/tasks/T-101.md` and recorded by T-101 in `docs/design/tokens.md` (the source of truth once it exists). Shell,
shared components and motion wrappers come from T-101; screen briefs only compose them.

"Harness" and `dev.local.harness` are placeholder names (hard rule 8: rename before release, never to anything
containing a provider trademark).

## Principles

- **A dense desktop tool with a calm surface.** One primary action per screen: it is the only filled accent button.
  Everything else is secondary, outline or ghost.
- **Generous whitespace.** Reading text is capped at about 65ch. Forms sit on solid surfaces (`--card`), never on
  translucent or animated ones.
- **Keyboard first.** ⌘K opens the command palette, ⌘1..⌘7 switch screens, ⌘Enter submits multi-line input, Esc
  closes overlays. Every interactive element shows a visible focus ring (`--ring`, 2px, offset 2px).
- **WCAG AA.** Text contrast is at least 4.5:1, and UI component boundaries and focus rings at least 3:1. Status is
  never shown by color alone: always an icon plus a text label.
- **Independent identity (rule 8).** Graphite neutrals plus one accent, orchid, which no provider uses. No provider
  logos, icons or brand colors, and no wording that suggests partnership ("official", "powered by", "partner").
  Provider and vendor names are plain text that comes only from `src/strings/providers.ts`.
- **Untrusted text stays text.** Anything a model, CLI or worker produced (lead messages, plan text, HANDOFF fields,
  diffs, test logs, terminal bytes) renders as React text nodes or inside xterm.js. It is never HTML, never markdown,
  and never auto-linked. Use `UntrustedText` from `src/components/common/`.
- **Honest copy about limits and credentials.** Say what the app does and doesn't do: "Harness never sees or stores
  your password", "Counters don't reset when you sign out". Never promise an outcome a provider controls.

## Components

- **shadcn/ui is the base for all functional UI:** Button, Input, Textarea, Select, Checkbox, RadioGroup, Form
  (react-hook-form + zod), Label, Card, Badge, Tabs, Dialog, AlertDialog, Sheet, Command, Tooltip, Sonner, Table,
  Accordion, Progress, ScrollArea, Separator, Switch, Alert, Skeleton, Sidebar, DropdownMenu, Popover, Toggle. Don't
  hand-roll a control shadcn already has. Screens never edit `src/components/ui/**`; ask the lead for changes.
- **Shared composites (T-101, `src/components/common/`):** ProviderName, UntrustedText, EmptyState, ErrorAlert,
  LoadingSkeleton, Countdown, Meter, CopyButton.
- **Icons:** lucide-react, generic glyphs only. Never use brand-like glyphs as provider stand-ins.
- **Out:** heavy effect libraries (Aceternity, Magic UI), background gradients, glassmorphism, parallax, confetti.

## Motion

- Motion runs on the `motion` package through Motion Primitives, and only through the wrappers in
  `src/components/motion/` (`Stagger`, `Shimmer`, `Reveal`, `PanelSwitch`). ESLint blocks direct imports elsewhere.
- Animate only transform and opacity. One documented exception is Text Shimmer, which animates `background-position`
  on one line of text. The human has been asked to confirm it (see the T-101 notes).
- Durations are 150-300 ms for UI and up to 600 ms for one-time entrances. Entrances ease out (`--ease-out`);
  presses use a spring.
- Each view has at most one signature effect, and every brief names it:
  - Animated Group: a stagger for cards and rows.
  - Text Shimmer: the lead's "thinking" state.
  - In View: an entrance.
  - Transition Panel: switching panels or tabs.
- When `prefers-reduced-motion` is set, every wrapper renders static content (the root also uses
  `MotionConfig reducedMotion="user"`).
- Forms never animate while the user types. Validation errors appear instantly, with no transition. Toasts (Sonner)
  are the only transient UI.

## Layout

- Desktop window, minimum 1024×700. Layout is a collapsible sidebar plus a header (page title, ⌘K button, theme
  menu). Content is at most 1200px wide.
- Radius is 14px on cards, 10px on inputs and buttons, and full-round on chips and badges. Shadows are soft and
  low-opacity.
- Light and dark themes come from CSS variables (`:root` and `.dark`), switched from the header or Settings. Light,
  dark and system are the options; the choice is saved locally.
- Terminals, diffs, logs, paths and hashes use the mono font. Terminals always use the `--terminal-*` tokens (dark in
  both themes).

## Typography

- UI and body text use Inter Variable: 16px base, line-height 1.55.
- Small text is 14px. 12px is for labels only.
- Headings are 24/20/16px, semibold.
- Mono text uses JetBrains Mono Variable at 13px, line-height 1.5.
- Both fonts are bundled through `@fontsource-variable/*`, so there is no runtime network fetch (rule 5, strict CSP).

## Palette summary (full table with contrast ratios in T-101)

| Role | Light | Dark |
|---|---|---|
| Background / card | `#F7F7F8` / `#FFFFFF` | `#111114` / `#18181C` |
| Text / muted text | `#17171B` / `#5B5B66` | `#ECECF1` / `#A1A1AD` |
| Accent (orchid, shadcn `--primary`) | `#9C1F6E` | `#F08BC8` |
| Success (olive) / warning (ochre) / danger (crimson) | `#3F6212` / `#8A5A00` / `#B42335` | `#A3C76A` / `#D8B35E` / `#FF8F8F` |

There is no blue, teal-green or clay-orange anywhere. Info states use neutral text, not a fourth hue.

## Every screen brief states, before any UI code

1. The screen goal, in one sentence.
2. The one primary action.
3. The tokens it uses.
4. An ASCII wireframe.
5. Its single signature motion and the library (Motion Primitives component) behind it, or "none".
6. Its loading, empty and error states. Each one is rendered from a mock scenario and covered by a test.
