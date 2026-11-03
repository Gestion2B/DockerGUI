FROM node:22-alpine

WORKDIR /app
COPY server.js ./server.js
COPY actualizador-ui ./actualizador-ui

EXPOSE 8780
CMD ["node", "server.js"]
