FROM node:20-alpine as build

WORKDIR /app

COPY package.json package-lock.json* ./

RUN npm ci

COPY . .

RUN npm run build

FROM nginx:alpine

COPY --from=build /app/dist /usr/share/nginx/html
COPY ./nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf

RUN mkdir -p /etc/letsencrypt
RUN mkdir -p /var/www/certbot

EXPOSE 80
EXPOSE 443

CMD ["nginx", "-g", "daemon off;"]
