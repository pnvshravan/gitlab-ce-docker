# gitlab-ce-docker

- Inspired by [hutchgrant](https://github.com/hutchgrant)'s Github [repository](https://github.com/hutchgrant/gitlab-docker-local).

---
### Terminologies:-

1. **Gitlab-CE**: GitLab Community Edition (CE) is an open source end-to-end software development platform with built-in version control, issue tracking, code review, CI/CD, and more. Self-host GitLab CE on your own servers, in a container, or on a cloud provider.

2. **Gitlab-runner**: Runners are the agents that run the CI/CD jobs that come from GitLab.

3. **Docker-in-Docker** (DinD): It refers to running a Docker engine (daemon) inside a Docker container, allowing you to build and manage other containers within the CI/CD pipeline, which is useful for testing and building containerized applications. 

---
## HTTPS config:
- Inside your gitlab-ce folder, add the following files:
1. Firstly, create a `docker-compose.yml` file with contents:
```
services:
  gitlab-server:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab-local-server-ssl
    hostname: gitlab-server
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://gitlab-server'

        # Disable Let's Encrypt
        letsencrypt['enable'] = false

        # GitLab NGINX Config
        nginx['listen_https'] = true
        nginx['listen_port'] = 443
        nginx['hsts_max_age'] = 0
        nginx['ssl_certificate'] = "/etc/gitlab/ssl/gitlab-server.crt"
        nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/gitlab-server.key"
        nginx['redirect_http_to_https'] = true
        nginx['ssl_dhparam'] = nil

        gitlab_rails['gitlab_host'] = 'gitlab-server'
        gitlab_rails['gitlab_port'] = 443
        gitlab_rails['initial_root_password'] = '?'

        puma['worker_processes'] = 0
        gitlab_rails['gitlab_shell_ssh_port'] = 8022

        # Registry Settings
        registry_external_url 'https://gitlab-server:9000'
        registry['enable'] = true
        gitlab_rails['registry_enabled'] = true
        gitlab_rails['registry_host'] = 'gitlab-server'
        gitlab_rails['registry_port'] = 9000
        gitlab_rails['registry_api_url'] = 'https://gitlab-server:9000'

        registry_nginx['listen_https'] = true
        registry_nginx['listen_port'] = 9000
        registry_nginx['ssl_certificate'] = "/etc/gitlab/ssl/gitlab-server.crt"
        registry_nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/gitlab-server.key"

    volumes:
      - ./gitlab/config:/etc/gitlab
      - ./gitlab/logs:/var/log/gitlab
      - ./gitlab/data:/var/opt/gitlab
      - ./gitlab/config/trusted-certs:/etc/gitlab/trusted-certs

      # SSL certs for nginx/registry
      - ./gitlab/ssl/gitlab-server.crt:/etc/gitlab/ssl/gitlab-server.crt
      - ./gitlab/ssl/gitlab-server.key:/etc/gitlab/ssl/gitlab-server.key

   
    ports:
      - '8500:80'
      - '443:443'
      - '9000:9000'
      - '8022:22'

    healthcheck:
      test: ["CMD", "curl", "-k", "--fail", "https://localhost/-/health"]
      interval: 60s
      timeout: 10s
      retries: 5

    networks:
      gitlab-network:
        aliases:
          - gitlab-server

  gitlab-runner:
    image: gitlab/gitlab-runner:alpine
    container_name: gitlab-runner-ssl
    privileged: true
    depends_on:
      gitlab-server:
        condition: service_healthy
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./gitlab-runner/config:/etc/gitlab-runner
      - /builds:/builds
      - /cache:/cache
      - ./certs/gitlab/gitlab-server.crt:/etc/gitlab-runner/certs/ca.crt
    networks:
      - gitlab-network
    extra_hosts:
     - "gitlab-server:172.28.0.2"

networks:
  gitlab-network:
    external: true
```
Note:
> The GitLab runner mounts your repo to `/builds/...` inside the Docker container running the pipeline.
> The DinD service `(docker:dind)` doesn't know about your runner mounts unless you explicitly reference them.

2. Create a `install_mkcert.sh` file with contents:
```
#!/bin/bash

Step 1: Install mkcert if not already installed
if ! command -v mkcert &> /dev/null; then
    echo "Installing mkcert..."
    sudo apt install libnss3-tools -y   # Required for mkcert on Linux
    wget https://dl.filippo.io/mkcert/latest?for=linux/amd64 -O mkcert
    chmod +x mkcert
    sudo mv mkcert /usr/local/bin/
fi

# Step 2: Set up mkcert CA (only runs once)
mkcert -install
```

3. Create a `setup_gitlab_ssl.sh` file with contents:
```
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
```
---
### Setup:
3. Ensure your network exists by running:
`docker network ls`
  - If you don't see "gitlab-network" listed, you'll need to create it manually before starting your docker-compose setup:
  `docker network create gitlab-network`

4. Run the `install_mkcert.sh` bash script on your terminal with command:
`sudo sh install_mkcert.sh`

- To verify if mkcert is installed properly on your machine, run this command on your terminal -
`mkcert -CAROOT` , and should show the directory where its got installed like below:
![](mkcert_img_1.png)

5.  Run the `setup_gitlab_ssl.sh` bash script on your terminal with command for the first time:
`sh setup_gitlab_ssl.sh`
- This script does the following things:
✅ Generates the certs.
✅ Copies everything to persistent volumes.  
✅ Waits for GitLab container to be healthy. 
✅ Installs and trusts the root CA persistently.
✅ Adds an DNS entry at path: /etc/hosts automatically.
✅ Starts up both containers for the first time and logs are shown in terminal.  

6. Run this command after you started your Gitlab server container to see its IP on another instance of your terminal:
`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' container_name`
- here, container_name (in this case - `gitlab-local-server-ssl`) which is mentioned in your `docker-compose.yml`.

7. In the terminal which shows up logs after Step-5, stop the containers using command: `docker compose down`. Now
replace the IP under `extra_hosts` variable of `gitlab-runner` service in your `docker-compose.yml` (86th line) with the IP shown when you run the Step-6.
```  
extra_hosts:
     - "gitlab-server:IP"
```
8. Change the Gitlab's initial root password to your liking at `docker-compose.yml` (24th line):
`gitlab_rails['initial_root_password'] = '?'`, where replace the `?` with your preferred password, where conditions are:
- The minimum password length is set to 8 characters by default, but you can increase this in the GitLab UI.
- GitLab also checks for weak passwords, such as those containing commonly used combinations or parts of your name, username, or email.
- Password should be a mix of special characters, number, capital letters,... 

9. Now start up the containers using the command: `docker compose up --build`
**Note:** Use the `--build` option only when changes are done in configuration. 
Otherwise:
- To start the containers: `docker compose up` 
- To stop the containers: `docker compose down`

---
### Post Setup:
1. Command to register a project runner for a specific repo:
```
docker exec -it gitlab-runner-ssl gitlab-runner register \
  --non-interactive \
  --url "https://gitlab-server" \
  --token "$RUNNER_TOKEN" \
  --docker-image "alpine:latest" \
  --executor "docker" \
  --description "docker-runner-ssl" \
  --docker-network-mode="gitlab-network" \
  --docker-privileged \
  --tls-ca-file "/etc/gitlab-runner/certs/ca.crt"
```
2. Command to see the config.toml file in `/gitlab-runner/config` folder :
`docker exec -it gitlab-runner cat /etc/gitlab-runner/config.toml`

**Note:**
- The **GitLab runner should be running in privileged mode**, which is often required for DinD.

- Make sure your GitLab Runner is configured with privileged mode enabled in `config.toml`:
```toml
[[runners]]
  ...
  [runners.docker]
    privileged = true
```
> Otherwise `DinD` won’t fully start properly (which matches your logs like: `mount: permission denied (are you root?)` and failing health checks).

3. After running the Step-2, there is a need to change some lines in the config.toml wrt runner, look for `volumes` under [runners. docker], where you will find `volumes = ["/cache"]`, and this line should be replaced with `volumes = ["/cache", "/etc/gitlab-runner/certs:/usr/local/share/ca-certificates:ro"]` and can be seen in below image:
![](runner_example.png)



---
### Errors encountered:

1. Error while deleting a project created in root.
![](error_1.png)

### ✅ Solution: Trust the mkcert Root CA **inside the GitLab container**

---
### References:
- Register a runner in Docker: https://docs.gitlab.com/runner/register/?tab=Docker
