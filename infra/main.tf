# ---------------------------------------------------------------------------
# Terraform for the NestJS release and rollback lab
# Creates: network, firewall, SSH key, one Ubuntu server (1 vCPU, 1 GB RAM),
# a fixed public IP, and sets the server up (Node.js, nginx, release folders,
# deploy and rollback scripts). No Docker is used anywhere.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project = "nest-release-demo"
      Owner   = var.owner
    }
  }
}

# ------------------------------- variables ---------------------------------

variable "region" {
  description = "AWS Region to deploy in"
  type        = string
  default     = "eu-west-2"
}

variable "owner" {
  description = "Your name prefix, used in resource names and tags"
  type        = string
  default     = "nice"
}

variable "instance_type" {
  description = "t2.micro = 1 vCPU and 1 GiB RAM (matches the task). If your Region has no t2, use t3.micro"
  type        = string
  default     = "t2.micro"
}

variable "ssh_cidr" {
  description = "Who may use SSH. GitHub-hosted runners change IP addresses, so the lab default is open to all, protected by the key only"
  type        = string
  default     = "0.0.0.0/0"
}

variable "public_key_path" {
  description = "Path to the PUBLIC half of your deploy key"
  type        = string
  default     = "~/.ssh/nest-deploy-key.pub"
}

# ------------------------------- network -----------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.owner}-nest-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.owner}-nest-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.30.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.owner}-nest-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.owner}-nest-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ------------------------------- firewall ----------------------------------

resource "aws_security_group" "app" {
  name        = "${var.owner}-nest-sg"
  description = "SSH for deployments, HTTP for the API"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH (deployments)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  ingress {
    description = "HTTP (the API through nginx)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound (package installs, updates)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.owner}-nest-sg" }
}

# ------------------------------- server ------------------------------------

resource "aws_key_pair" "deploy" {
  key_name   = "${var.owner}-nest-deploy-key"
  public_key = file(pathexpand(var.public_key_path))
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = aws_key_pair.deploy.key_name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 12
    volume_type = "gp3"
    encrypted   = true
  }

  # Runs once at first boot as root. It builds the server so deployments are simple.
  user_data = <<EOT
#!/bin/bash
set -eux
exec > >(tee /var/log/user-data.log) 2>&1

# 1) Swap file: 1 GB of RAM is tight, swap stops out-of-memory crashes
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 2) Install nginx and Node.js 20 (runtime only, the app is built by GitHub Actions)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx curl ca-certificates
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# 3) A locked-down user that runs the app, and the release folders
useradd --system --home /opt/nestapp --shell /usr/sbin/nologin nestapp || true
mkdir -p /opt/nestapp/releases /opt/nestapp/shared /opt/nestapp/bin
chown -R ubuntu:ubuntu /opt/nestapp
chmod -R 755 /opt/nestapp

# 4) nginx: public port 80 forwards to the app on 127.0.0.1:3000
cat > /etc/nginx/sites-available/default <<'NGINX'
server {
    listen 80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX
systemctl restart nginx

# 5) systemd service. WorkingDirectory is the "current" symlink, so changing the
#    symlink and restarting the service switches the running version.
cat > /etc/systemd/system/nestapp.service <<'UNIT'
[Unit]
Description=NestJS release demo
After=network.target

[Service]
Type=simple
User=nestapp
WorkingDirectory=/opt/nestapp/current
ExecStart=/usr/bin/node dist/main.js
Environment=NODE_ENV=production
Environment=PORT=3000
Restart=on-failure
RestartSec=3
MemoryMax=600M

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable nestapp

# 6) deploy.sh: unpack a new release, switch the symlink, check health, undo if it fails
cat > /opt/nestapp/bin/deploy.sh <<'DEPLOY'
#!/bin/bash
set -euo pipefail
if [ $# -ne 2 ]; then echo "Usage: deploy.sh VERSION PACKAGE.tar.gz"; exit 1; fi
VERSION="$1"
PKG="$2"
BASE=/opt/nestapp
REL="$BASE/releases/$VERSION"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Bad version: $VERSION"; exit 1; fi

PREV=""
if [ -L "$BASE/current" ]; then PREV="$(readlink -f "$BASE/current")"; fi

echo "Unpacking $VERSION into $REL"
rm -rf "$REL"
mkdir -p "$REL"
tar xzf "$PKG" -C "$REL"
rm -f "$PKG"

echo "Switching the current symlink to $VERSION"
ln -sfn "$REL" "$BASE/current.tmp"
mv -T "$BASE/current.tmp" "$BASE/current"
sudo systemctl restart nestapp

for i in $(seq 1 15); do
  if curl -fs http://127.0.0.1:3000/health | grep -q "\"version\":\"$VERSION\""; then
    echo "Health check passed. Version $VERSION is live."
    if [ -n "$PREV" ]; then basename "$PREV" > "$BASE/shared/previous_version"; fi
    CUR="$(readlink -f "$BASE/current")"
    ls -1dt "$BASE"/releases/* | tail -n +6 | grep -vx "$CUR" | xargs -r rm -rf || true
    exit 0
  fi
  sleep 2
done

echo "Health check FAILED for $VERSION"
if [ -n "$PREV" ]; then
  echo "Rolling back automatically to $(basename "$PREV")"
  ln -sfn "$PREV" "$BASE/current.tmp"
  mv -T "$BASE/current.tmp" "$BASE/current"
  sudo systemctl restart nestapp
fi
exit 1
DEPLOY

# 7) rollback.sh: point "current" at an older version that is still on the server
cat > /opt/nestapp/bin/rollback.sh <<'ROLLBACK'
#!/bin/bash
set -euo pipefail
if [ $# -ne 1 ]; then echo "Usage: rollback.sh VERSION"; /opt/nestapp/bin/status.sh; exit 1; fi
VERSION="$1"
BASE=/opt/nestapp
REL="$BASE/releases/$VERSION"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Bad version: $VERSION"; exit 1; fi
if [ ! -d "$REL" ]; then echo "Version $VERSION is not on this server."; /opt/nestapp/bin/status.sh; exit 1; fi

echo "Rolling back to $VERSION"
ln -sfn "$REL" "$BASE/current.tmp"
mv -T "$BASE/current.tmp" "$BASE/current"
sudo systemctl restart nestapp

for i in $(seq 1 15); do
  if curl -fs http://127.0.0.1:3000/health | grep -q "\"version\":\"$VERSION\""; then
    echo "Rollback complete. Version $VERSION is live."
    exit 0
  fi
  sleep 2
done
echo "Rollback health check FAILED"
exit 1
ROLLBACK

# 8) status.sh: which version is live and which versions are stored
cat > /opt/nestapp/bin/status.sh <<'STATUS'
#!/bin/bash
BASE=/opt/nestapp
echo "Current release folder: $(readlink -f "$BASE/current" 2>/dev/null || echo none)"
echo "Versions on this server:"
ls -1 "$BASE/releases" 2>/dev/null
echo "Service: $(systemctl is-active nestapp)"
echo "Health: $(curl -fs http://127.0.0.1:3000/health || echo unreachable)"
STATUS

chmod +x /opt/nestapp/bin/*.sh
chown -R ubuntu:ubuntu /opt/nestapp
echo "Server setup finished"
EOT

  tags = { Name = "${var.owner}-nest-server" }

  depends_on = [aws_internet_gateway.igw]
}

# A fixed public IP so GitHub Actions and your browser always find the server
resource "aws_eip" "app" {
  domain     = "vpc"
  instance   = aws_instance.app.id
  tags       = { Name = "${var.owner}-nest-eip" }
  depends_on = [aws_internet_gateway.igw]
}

# ------------------------------- outputs -----------------------------------

output "server_public_ip" {
  description = "Put this in the GitHub secret SERVER_HOST"
  value       = aws_eip.app.public_ip
}

output "app_url" {
  value = "http://${aws_eip.app.public_ip}"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/nest-deploy-key ubuntu@${aws_eip.app.public_ip}"
}
