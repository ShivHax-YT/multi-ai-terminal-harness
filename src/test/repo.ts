// File helpers for the guard tests (read-only, inside the repo).
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

export const ROOT = path.resolve(import.meta.dirname, "../..");

export function readRepo(rel: string): string {
  return readFileSync(path.join(ROOT, rel), "utf8");
}

export function readJson(rel: string): unknown {
  return JSON.parse(readRepo(rel)) as unknown;
}

/** Repo-relative paths of every file under `dir` (posix separators). */
export function listFiles(dir: string): string[] {
  const out: string[] = [];
  const walk = (rel: string) => {
    for (const name of readdirSync(path.join(ROOT, rel))) {
      const child = `${rel}/${name}`;
      if (statSync(path.join(ROOT, child)).isDirectory()) walk(child);
      else out.push(child);
    }
  };
  walk(dir);
  return out.sort();
}

export const isTestFile = (rel: string): boolean =>
  rel.startsWith("src/test/") || /\.test\.tsx?$/.test(rel);
