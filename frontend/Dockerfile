
# ---------- Στάδιο 1: Build της Angular εφαρμογής ----------
FROM node:22-alpine AS build
 
WORKDIR /app
 
# Πρώτα μόνο τα package files, ώστε το npm ci να γίνεται cache
COPY package*.json ./
RUN npm ci
 
# Ο υπόλοιπος κώδικας
COPY . .
 
# Production build
RUN npx ng build --configuration production
 
 
# ---------- Στάδιο 2: Σερβίρισμα με Nginx ----------
FROM nginx:1.27-alpine
 
# Ρυθμίσεις Nginx για Single Page Application
COPY nginx.conf /etc/nginx/conf.d/default.conf
 
# Αντιγραφή των αρχείων του build (Angular 17+: dist/<όνομα-project>/browser)
COPY --from=build /app/dist/*/browser /usr/share/nginx/html
 
EXPOSE 80
 
CMD ["nginx", "-g", "daemon off;"]
 