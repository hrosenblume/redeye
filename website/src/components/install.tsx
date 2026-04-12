"use client";

import { useState } from "react";

const steps = [
  {
    label: "Download",
    code: "# Download Redeye.app.zip from GitHub and unzip it\n# Move Redeye.app to /Applications",
  },
  {
    label: "Clear quarantine",
    code: "xattr -cr /Applications/Redeye.app",
  },
  {
    label: "Launch",
    code: "open /Applications/Redeye.app",
  },
];

export function Install() {
  const [copied, setCopied] = useState<number | null>(null);

  function copy(text: string, index: number) {
    navigator.clipboard.writeText(text);
    setCopied(index);
    setTimeout(() => setCopied(null), 2000);
  }

  return (
    <section id="install" className="mx-auto max-w-2xl px-6 py-20">
      <h2 className="mb-12 text-center text-3xl font-bold tracking-tight">
        Install in 3 steps
      </h2>
      <div className="space-y-6">
        {steps.map((step, i) => (
          <div key={step.label}>
            <div className="mb-2 text-sm font-medium text-zinc-400">
              {i + 1}. {step.label}
            </div>
            <div className="group relative rounded-lg border border-zinc-800 bg-zinc-900 p-4 font-mono text-sm">
              <pre className="overflow-x-auto whitespace-pre text-zinc-300">
                {step.code}
              </pre>
              <button
                onClick={() => copy(step.code, i)}
                className="absolute right-3 top-3 rounded border border-zinc-700 bg-zinc-800 px-2 py-1 text-xs text-zinc-400 opacity-0 transition-opacity group-hover:opacity-100 hover:text-white"
              >
                {copied === i ? "Copied" : "Copy"}
              </button>
            </div>
          </div>
        ))}
      </div>
      <div className="mt-8 rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 text-sm text-zinc-400">
        <strong className="text-zinc-300">Prerequisites:</strong>{" "}
        <a
          href="https://formulae.brew.sh/formula/tmux"
          className="underline hover:text-white"
        >
          tmux
        </a>{" "}
        and{" "}
        <a
          href="https://claude.ai/code"
          className="underline hover:text-white"
        >
          Claude Code
        </a>
      </div>
    </section>
  );
}
