import { Hero } from "@/components/hero";
import { Features } from "@/components/features";
import { Install } from "@/components/install";
import { Footer } from "@/components/footer";

export default function Home() {
  return (
    <main className="flex-1">
      <Hero />
      <Features />
      <Install />
      <Footer />
    </main>
  );
}
