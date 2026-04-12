export function Hero() {
  return (
    <section className="flex flex-col items-center justify-center px-6 pt-32 pb-20">
      <div className="mb-6 text-6xl">&#9749;</div>
      <h1 className="text-center text-5xl font-bold tracking-tight sm:text-6xl">
        Keep your Claude awake
      </h1>
      <p className="mt-6 max-w-xl text-center text-lg leading-8 text-zinc-400">
        An app for Mac that keeps Claude Code running in the background.
      </p>
      <div className="mt-10 flex gap-4">
        <a
          href="https://github.com/hrosenblume/redeye/releases/latest/download/Redeye.app.zip"
          className="rounded-full bg-white px-6 py-3 text-sm font-semibold text-black transition-colors hover:bg-zinc-200"
        >
          Download for Mac
        </a>
        <a
          href="#install"
          className="rounded-full border border-zinc-700 px-6 py-3 text-sm font-semibold text-zinc-300 transition-colors hover:border-zinc-500 hover:text-white"
        >
          How to install
        </a>
      </div>
    </section>
  );
}
