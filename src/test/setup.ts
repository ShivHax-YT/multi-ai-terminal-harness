// Vitest setup (jsdom): jest-dom matchers, cleanup, and the browser APIs jsdom lacks that shadcn/Radix and Motion use.
import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

afterEach(() => {
  cleanup();
  localStorage.clear();
  document.documentElement.classList.remove("dark");
  window.location.hash = "";
});

let reducedMotion = false;

/** Tests flip `prefers-reduced-motion` with this; every other media query reports false. */
export function setReducedMotion(value: boolean): void {
  reducedMotion = value;
}

Object.defineProperty(window, "matchMedia", {
  writable: true,
  configurable: true,
  value: (query: string): MediaQueryList => {
    const matches = query.includes("prefers-reduced-motion") ? reducedMotion : false;
    const mql = {
      matches,
      media: query,
      onchange: null,
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
      dispatchEvent: () => false,
    };
    return mql as unknown as MediaQueryList;
  },
});

class ResizeObserverStub {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}

class IntersectionObserverStub {
  readonly root = null;
  readonly rootMargin = "";
  readonly thresholds: readonly number[] = [];
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
  takeRecords(): IntersectionObserverEntry[] {
    return [];
  }
}

function polyfill(target: object, key: string, value: unknown): void {
  if (!(key in target)) {
    Object.defineProperty(target, key, { value, configurable: true, writable: true });
  }
}

polyfill(globalThis, "ResizeObserver", ResizeObserverStub);
polyfill(globalThis, "IntersectionObserver", IntersectionObserverStub);
polyfill(Element.prototype, "scrollIntoView", () => undefined);
polyfill(Element.prototype, "hasPointerCapture", () => false);
polyfill(Element.prototype, "releasePointerCapture", () => undefined);
