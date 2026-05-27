# Codebase Changes Summary

This document outlines the modifications made to the repository to transition the CI/CD pipeline from AWS ECR to GCP Artifact Registry, and to adapt the Helm deployment from a managed Google Kubernetes Engine (GKE) environment to a custom on-premise style Kubernetes cluster (using `kubeadm` with NGINX Ingress and generic storage).

## 1. `jenkinsfile`

The Jenkins pipeline was overhauled to authenticate with Google Cloud Platform and push Docker images to Artifact Registry instead of AWS Elastic Container Registry.

### Environment Variables Updated
**Before:**
```groovy
  environment {
    AWS_REGION      = 'us-east-1'
    IMAGE_TAG       = "${BUILD_NUMBER}"
    GITHUB_REPO    = credentials('github-repo-url')
    SONARQUBE_URL  = credentials('SONARQUBE_URL')
  }
```

**After:**
```groovy
  environment {
    GCP_REGION      = 'asia-south1'
    GCP_PROJECT_ID  = 'robot-shop-gke-madhu'
    GCP_REGISTRY    = "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/robot-shop"
    IMAGE_TAG       = "${BUILD_NUMBER}"
    GITHUB_REPO    = credentials('github-repo-url')
    SONARQUBE_URL  = credentials('SONARQUBE_URL')
  }
```

### Docker Build & Push Stage
*   **Renamed** the stage from `Docker Build & Push to ECR` to `Docker Build & Push to GCP`.
*   **Authentication:** Replaced the AWS CLI `aws ecr get-login-password` logic with a standard `docker login` authenticated via a GCP Service Account JSON key stored in Jenkins credentials (`gcp-artifact-registry-creds`).
*   **Image Tagging:** Updated the docker build and push commands to tag the images with `$GCP_REGISTRY` instead of `$ECR_REGISTRY`.

### Helm Values Update Stage
*   Removed AWS credential bindings.
*   Updated the `sed` substitution commands to inject the `GCP_REGISTRY` path into the Helm `values.yaml` file.
*   Retained the automated Git commit and push back to the `main` branch.

---

## 2. `K8s/helm/values.yaml`

The Helm chart values were adjusted to pull from the new GCP registry and to work seamlessly on a custom bare-metal/kubeadm cluster rather than relying on GKE-specific cloud providers.

### Image Repository & Pull Secret
*   **`image.repo`**: Updated to `asia-south1-docker.pkg.dev/robot-shop-gke-madhu/robot-shop`.
*   **`image.pullSecret`**: Changed from `ecr-secret` to `gcp-registry-secret` (this secret must be created manually in the cluster to allow pulling private images).

### Persistence (Storage Classes)
*   **`persistence.mongodb.storageClass`**: Changed from `standard-rwo` (which is a specific GKE provisioner) to `standard`.
*   **`persistence.mysql.storageClass`**: Changed from `standard-rwo` to `standard`.
*   *Reason:* Custom Kubernetes clusters usually have a default storage class named `standard` (or you can install a provisioner like Rancher Local Path) instead of the proprietary GKE drivers.

### Ingress Configuration
*   **`ingress.annotations`**: 
    *   Changed `kubernetes.io/ingress.class` from `gce` to `nginx`.
    *   *Reason:* The `gce` ingress class invokes the Google Cloud HTTP(S) Load Balancer, which only works if the cluster is a managed GKE cluster. For custom Compute Engine VMs, the open-source NGINX Ingress Controller is the standard approach.

---

## 3. New Files Added

### `GCP_K8s_Setup_Guide.md`
*   Created a comprehensive guide detailing how to provision a custom VPC, create Compute Engine instances, prepare the Linux OS (disable swap, kernel modules, containerd), and bootstrap a Kubernetes cluster using `kubeadm` on GCP.
