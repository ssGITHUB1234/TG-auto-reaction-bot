
FROM node:18-slim

WORKDIR /app

# Copy package JSON and lockfile if present
COPY package.json package-lock.json* ./

# If package-lock.json exists use npm ci for reproducible installs,
# otherwise fall back to npm install. Use --omit=dev to avoid dev deps.
RUN if [ -f package-lock.json ]; then \
      npm ci --omit=dev; \
    else \
      npm install --omit=dev; \
    fi

COPY . .

ENV PORT=3000
EXPOSE 3000
CMD ["node", "server.js"]
