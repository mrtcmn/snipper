FROM node:24-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
# ponytail: npm ci rejects the lockfile on Linux (npm bug with the bundled @emnapi deps of tailwind oxide-wasm32); npm install still honours it.
RUN npm install --no-audit --no-fund
COPY . .
RUN npm run build && npm prune --omit=dev

FROM oven/bun:1.4.2-slim
WORKDIR /app
ENV NODE_ENV=production PORT=3000
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY server.ts package.json ./
EXPOSE 3000
USER bun
CMD ["bun", "server.ts"]
