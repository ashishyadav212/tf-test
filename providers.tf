terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.28.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

provider "google" {
  project = "assign212"
  region  = "asia-south1"
  zone    = "asia-south1-a"
}

# Kubernetes provider
provider "kubernetes" {
  host = "https://${data.google_container_cluster.cluster.endpoint}"

  token = data.google_client_config.default.access_token

  cluster_ca_certificate = base64decode(
    data.google_container_cluster.cluster.master_auth[0].cluster_ca_certificate
  )
}

