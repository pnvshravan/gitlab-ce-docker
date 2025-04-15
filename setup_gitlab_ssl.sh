#!/bin/bash

#Generate SSL certificate for GitLab
domain="gitlab-server.local"
container="gitlab-local-server-ssl"

mkdir -p certs/gitlab
cd certs/gitlab || exit
mkcert -cert-file ${domain}.crt -key-file ${domain}.key ${domain}
cd ../..

# Copy cert + key for mounting into GitLab NGINX
mkdir -p gitlab/ssl
cp ./certs/gitlab/${domain}.crt ./gitlab/ssl/
cp ./certs/gitlab/${domain}.key ./gitlab/ssl/

# Copy mkcert root CA for trust
cp "$(mkcert -CAROOT)/rootCA.pem" ./certs/gitlab/mkcert-rootCA.crt

# Copy mkcert CA to GitLab's built-in trusted certs location
mkdir -p gitlab/config/trusted-certs
cp ./certs/gitlab/mkcert-rootCA.crt ./gitlab/config/trusted-certs/

echo "🚀 Starting GitLab with Docker Compose..."
docker compose up -d --build

#Add domain to /etc/hosts
echo "127.0.0.1 ${domain}" | sudo tee -a /etc/hosts

# Validate container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
  echo "❌ Container '$container' is not running. Please start it using 'docker compose up -d'."
  exit 1
fi

# Wait for health check to pass
echo "⏳ Waiting for GitLab container to be healthy..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null)" = "healthy" ]; do
  echo "   🕒 Waiting for container healthcheck..."
  sleep 5
done

echo "🔐 Trusting mkcert CA inside container..."
docker exec -it $container update-ca-certificates

echo "🔧 Making Ruby trust mkcert CA..."
docker exec -it $container bash -c "cp /etc/ssl/certs/ca-certificates.crt /opt/gitlab/embedded/ssl/certs/cacert.pem"

echo "♻️ Restarting GitLab services..."
docker exec -it $container gitlab-ctl reconfigure
docker exec -it $container gitlab-ctl restart

echo "✅ Done! GitLab should now trust mkcert CA and be fully functional with SSL."
echo "Setup complete! 🛠️ Access GitLab at: https://${domain}"

echo "📋 Showing logs from container $container..."

docker logs -f "$container"
