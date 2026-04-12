const features = [
  {
    title: "Menu bar native",
    description:
      "Lives in your menu bar with a coffee cup icon. Filled when running, outlined when stopped. No dock clutter.",
  },
  {
    title: "Multi-project",
    description:
      "Manage multiple project directories, each with its own independent Claude Code session running in the background.",
  },
  {
    title: "One-click attach",
    description:
      "Open any running session in Terminal directly from the menu. Pick up right where Claude left off.",
  },
  {
    title: "Auto-start",
    description:
      "Configure a LaunchAgent and Redeye starts your sessions automatically on login. Set it and forget it.",
  },
  {
    title: "Zero config",
    description:
      "Just add a folder. Redeye handles session naming, lifecycle management, and status polling automatically.",
  },
  {
    title: "Remote control",
    description:
      "Sessions stay alive so you can connect from anywhere using Claude's remote control mode. Start at your desk, continue from your phone.",
  },
];

export function Features() {
  return (
    <section className="mx-auto max-w-5xl px-6 py-20">
      <h2 className="mb-12 text-center text-3xl font-bold tracking-tight">
        What it does
      </h2>
      <div className="grid gap-8 sm:grid-cols-2 lg:grid-cols-3">
        {features.map((f) => (
          <div
            key={f.title}
            className="rounded-xl border border-zinc-800 bg-zinc-900/50 p-6"
          >
            <h3 className="mb-2 text-lg font-semibold">{f.title}</h3>
            <p className="text-sm leading-6 text-zinc-400">{f.description}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
