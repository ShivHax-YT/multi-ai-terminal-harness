// Model, CLI and worker text (lead messages, plan text, HANDOFF fields, diffs, logs, IPC error messages) renders
// only through this component: a React text node, whitespace kept, never HTML, never markdown, never auto-linked.
import { cn } from "@/lib/utils";

export interface UntrustedTextProps {
  text: string;
  /** Mono font (terminals, diffs, logs, paths, hashes). */
  mono?: boolean;
  /** Block element (`div`) instead of inline (`span`). */
  block?: boolean;
  className?: string;
}

export function UntrustedText({ text, mono = false, block = false, className }: UntrustedTextProps) {
  const Tag = block ? "div" : "span";
  return (
    <Tag
      data-untrusted=""
      dir="auto"
      className={cn(
        "break-words whitespace-pre-wrap",
        mono && "font-mono text-[13px] leading-[1.5]",
        className,
      )}
    >
      {text}
    </Tag>
  );
}
