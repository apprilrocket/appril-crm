/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,

  experimental: {
    serverActions: { bodySizeLimit: '2mb' },
  },

  // Omite type-check y lint en build — correr tsc por separado cuando necesites
  typescript: { ignoreBuildErrors: true },
  eslint:     { ignoreDuringBuilds: true },
};

export default nextConfig;
