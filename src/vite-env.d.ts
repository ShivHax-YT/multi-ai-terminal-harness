/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** "tauri" makes `pnpm dev` talk to the real backend instead of the mock. Ignored in production builds. */
  readonly VITE_HARNESS_IPC?: string;
  /** Dev mock scenario (src/lib/ipc/mock/backend.ts MOCK_SCENARIOS). Ignored in production builds. */
  readonly VITE_HARNESS_MOCK_SCENARIO?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
