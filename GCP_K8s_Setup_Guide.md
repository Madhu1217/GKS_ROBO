# Complete GCP Compute Engine Kubernetes Setup Guide

This document provides a comprehensive, step-by-step guide to setting up a Kubernetes cluster from scratch using Google Compute Engine (GCE) VMs, along with detailed explanations for *why* each step is necessary.

---

## Part 1: Setting Up Networking & Firewalls in GCP

Kubernetes is a complex network of computers acting as one. We must build a secure foundation for them to communicate.

**The "Why":**
*   **VPC & Subnet:** A Virtual Private Cloud isolates your network. We use a custom subnet to control the IP ranges.
*   **Internal Firewall:** Kubernetes components (API server, Kubelets, Pods) constantly talk to each other. We must open all internal ports (`tcp,udp,icmp`).
*   **SSH Firewall:** We need port `22` open to log into the VMs and install software.
*   **Web Firewall:** Ports `80` and `443` must be open so internet traffic can reach your Ingress controller.

**Commands:**
Run these in your terminal (ensure you are authenticated via `gcloud auth login` and your project is set):

```bash
# 1. Create a custom VPC network
gcloud compute networks create k8s-vpc --subnet-mode custom

# 2. Create a subnet (using asia-south1)
gcloud compute networks subnets create k8s-subnet \
  --network k8s-vpc \
  --range 10.240.0.0/24 \
  --region asia-south1

# 3. Allow internal communication
gcloud compute firewall-rules create k8s-allow-internal \
  --network k8s-vpc \
  --allow tcp,udp,icmp \
  --source-ranges 10.240.0.0/24

# 4. Allow SSH access
gcloud compute firewall-rules create k8s-allow-ssh \
  --network k8s-vpc \
  --allow tcp:22 \
  --source-ranges 0.0.0.0/0

# 5. Allow HTTP/HTTPS traffic
gcloud compute firewall-rules create k8s-allow-web \
  --network k8s-vpc \
  --allow tcp:80,tcp:443 \
  --source-ranges 0.0.0.0/0
```

---

## Part 2: Create the Compute Engine VMs

We need at least one Master node and one Worker node.

**The "Why":**
*   **Master Node:** The control plane. It runs the API server, database (`etcd`), and scheduler.
*   **Worker Node:** Does the heavy lifting, running your application containers.
*   **Machine Type:** Kubernetes requires a minimum of **2 CPUs** (`e2-medium`). It will fail to initialize on a 1-CPU machine.

**Commands:**

```bash
# 1. Create the Master Node
gcloud compute instances create k8s-master \
  --zone asia-south1-a \
  --machine-type e2-medium \
  --image-family ubuntu-2204-lts \
  --image-project ubuntu-os-cloud \
  --boot-disk-size 50GB \
  --network k8s-vpc \
  --subnet k8s-subnet \
  --tags k8s-node

# 2. Create the Worker Node
gcloud compute instances create k8s-worker-1 \
  --zone asia-south1-a \
  --machine-type e2-medium \
  --image-family ubuntu-2204-lts \
  --image-project ubuntu-os-cloud \
  --boot-disk-size 50GB \
  --network k8s-vpc \
  --subnet k8s-subnet \
  --tags k8s-node
```

---

## Part 3: Install Kubernetes Components (OS Preparation)

Run these commands on **ALL VMs** (SSH into them using `gcloud compute ssh <instance-name> --zone asia-south1-a`).

**The "Why":**
*   **Disable Swap:** Kubernetes must strictly manage memory limits. If Linux uses swap, Kubernetes loses track of memory, causing instability.
*   **Kernel Modules:** Loads drivers needed for overlay networks, allowing containers on different VMs to communicate.
*   **sysctl IPv4 Forwarding:** Allows the Linux OS to route traffic from a Pod to the outside world.
*   **Containerd & SystemdCgroup:** Kubernetes delegates running containers to `containerd`. Telling it to use `SystemdCgroup` prevents conflicts between `kubelet` and `systemd` over resource management.
*   **kubeadm, kubelet, kubectl:** The core tools. `kubeadm` bootstraps the cluster, `kubelet` manages containers on the node, and `kubectl` is your CLI interface.

**Commands (Run on ALL VMs):**

```bash
# Disable swap
sudo swapoff -a

# Setup kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Setup sysctl parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Install containerd
sudo apt-get update
sudo apt-get install -y containerd apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd

# Install kubeadm, kubelet, kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

## Part 4: Initialize the Master Node

Run these commands ONLY on `k8s-master`.

**The "Why":**
*   **kubeadm init:** Turns the VM into a Master. We pass the internal IP to bind the API server correctly. The `--pod-network-cidr` defines the IP range for pods, required by Calico.
*   **kubeconfig:** Copies the admin certificate so you can use `kubectl` locally.
*   **Calico (CNI):** Sets up the routing tables between pods. Without it, nodes stay `NotReady`.
*   **NGINX Ingress:** Acts as the front door, listening on ports 80/443 to route internet traffic to internal services.

**Commands (Run on k8s-master):**

```bash
# Get the internal IP of the master node
INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

# Initialize the cluster
sudo kubeadm init --apiserver-advertise-address=$INTERNAL_IP --pod-network-cidr=192.168.0.0/16

# Set up kubectl for the current user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Calico Network Plugin
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml

# Install NGINX Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml
```

**CRITICAL:** Save the `kubeadm join` command printed at the end of the initialization output!

---

## Part 5: Join the Worker Nodes

Run this ONLY on `k8s-worker-1`.

**The "Why":**
Worker nodes use the secure token to authenticate with the Master, preventing unauthorized VMs from joining.

**Command (Run on k8s-worker-1):**

```bash
# Paste the command copied from the Master node output
sudo kubeadm join <MASTER_INTERNAL_IP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Verify on the Master node by running `kubectl get nodes`.

---

## Part 6: Deploy Application using Helm

Run this on `k8s-master`.

**The "Why":**
Helm is the package manager for K8s. It reads your `values.yaml` and deploys the entire application stack as a single release. We also create a secret so Kubernetes can pull images from your private GCP Artifact Registry.

**Commands (Run on k8s-master):**

```bash
# 1. Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 2. Create the GCP registry secret (replace paths/emails)
kubectl create secret docker-registry gcp-registry-secret \
  --docker-server=asia-south1-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat /path/to/your/gcp-service-account-key.json)" \
  --docker-email="your-email@example.com"

# 3. Clone your code (if not already present) and deploy
helm upgrade --install robot-shop ./K8s/helm
```

---

## Part 7: Troubleshooting - Pods Stuck in Pending/CrashLoopBackOff

If you have deployed the application using Helm but notice that your database pods (MongoDB, MySQL, Redis) are stuck in a `Pending` state, and other microservices are failing/crashing, it is likely due to a missing **Storage Class**.

**The "Why":**
Because this cluster was built from scratch using `kubeadm` on raw VMs, it does not have a default Storage Class provider out of the box (unlike managed services like GKE or EKS). When the Helm chart attempts to create `PersistentVolumeClaims` (PVCs) for the databases, Kubernetes doesn't know how to fulfill them.

### Fix: Install Local Path Provisioner

Run these commands on your **master node** to install a local path provisioner. This tells Kubernetes to use the local disk of the worker nodes to satisfy the storage requests.

```bash
# 1. Install the Rancher local-path-provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml

# 2. Set it as the default storage class
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 3. (Optional but recommended) Alias the provisioner to 'standard' if your Helm chart hardcodes it
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
```

After running these commands, Kubernetes should be able to create the volumes, and your database pods will start automatically.
