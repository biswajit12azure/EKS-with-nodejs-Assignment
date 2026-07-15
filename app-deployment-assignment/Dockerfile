# ── Stage 1: build & test ──────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY app/package*.json ./
RUN npm ci --only=production

COPY app/src ./src

# ── Stage 2: production image ─────────────────────────────────────────────────
FROM node:20-alpine AS production

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# Run as non-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/src ./src
COPY app/package.json ./

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/index.js"]
