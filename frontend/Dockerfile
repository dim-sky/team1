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

# Πού στέλνει το nginx τα αιτήματα /api/ (το Azure το αλλάζει μέσω env var)
ENV BACKEND_URL=http://backend:8000

# Template: το nginx αντικαθιστά το ${BACKEND_URL} κατά την εκκίνηση
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

# Αντιγραφή των αρχείων του build (Angular 17+: dist/<όνομα-project>/browser)
COPY --from=build /app/dist/*/browser /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
