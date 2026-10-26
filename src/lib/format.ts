// Number formatting for usage and spend. Money is USD (contract convention).

const usd = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/** "$3.42". */
export function formatUsd(value: number): string {
  return usd.format(Number.isFinite(value) ? value : 0);
}

/** "45 min", "1 h 30 min", "8 h". */
export function formatMinutes(minutes: number): string {
  const total = Number.isFinite(minutes) ? Math.max(0, Math.round(minutes)) : 0;
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${String(m)} min`;
  if (m === 0) return `${String(h)} h`;
  return `${String(h)} h ${String(m)} min`;
}

/** "950", "182.4k", "1.2M" (one decimal, trailing ".0" dropped). */
export function formatTokens(value: number): string {
  const n = Number.isFinite(value) ? Math.max(0, Math.round(value)) : 0;
  const short = (v: number, suffix: string) =>
    `${(Math.round(v * 10) / 10).toFixed(1).replace(/\.0$/, "")}${suffix}`;
  if (n >= 1_000_000) return short(n / 1_000_000, "M");
  if (n >= 1_000) return short(n / 1_000, "k");
  return String(n);
}
