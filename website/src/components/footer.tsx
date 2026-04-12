export function Footer() {
  return (
    <footer className="border-t border-zinc-800 px-6 py-10 text-center text-sm text-zinc-500">
      <p>
        Built by{" "}
        <a
          href="https://github.com/hrosenblume"
          className="text-zinc-400 underline hover:text-white"
        >
          Hunter Rosenblume
        </a>
      </p>
      <p className="mt-1">
        <a
          href="https://github.com/hrosenblume/redeye"
          className="text-zinc-400 underline hover:text-white"
        >
          View source on GitHub
        </a>
      </p>
    </footer>
  );
}
