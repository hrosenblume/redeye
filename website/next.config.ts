import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export",
  basePath: "/redeye",
  images: { unoptimized: true },
};

export default nextConfig;
