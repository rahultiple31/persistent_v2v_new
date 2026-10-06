# syntax=docker/dockerfile:1
# For reproducible builds, pin both stages to a digest: node:22-alpine@sha256:<digest>
#
# The dependencies are plain JavaScript (no native modules), so they are installed on the build
# machine's own architecture and copied into the ARM64 runtime image. No build step runs ARM64 code,
# so an x86 machine (AWS CloudShell, most CI runners) builds this image without emulation.

FROM --platform=$BUILDPLATFORM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
# Application files stay owned by root and the process runs as the unprivileged "node" user, so the
# running service cannot modify its own code. ECS also mounts the root filesystem read-only.
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
USER node
EXPOSE 8080
CMD ["node", "src/index.js"]
