import "@fontsource-variable/inter";
import "@fontsource-variable/jetbrains-mono";
import "@/styles/globals.css";

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "@/app/app";
import { loadIpc } from "@/lib/ipc";

const root = document.getElementById("root");
if (root === null) throw new Error("missing #root");

void loadIpc().then((bundle) => {
  createRoot(root).render(
    <StrictMode>
      <App bundle={bundle} />
    </StrictMode>,
  );
});
