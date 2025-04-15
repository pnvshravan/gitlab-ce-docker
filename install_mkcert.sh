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


