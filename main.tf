// Hub VPC
resource "google_compute_network" "vpc" {
  name                            = "hub-vpc"
  auto_create_subnetworks         = false
  delete_default_routes_on_create = true # default route not created
}

// Shared VPC Configuration
// 1. Enable the Host Project
resource "google_compute_shared_vpc_host_project" "host" {
  project = data.google_client_config.default.project
}

// 2. Link a Service Project (Replace 'service-project-id' with your actual project ID)
resource "google_compute_shared_vpc_service_project" "service" {
  host_project    = google_compute_shared_vpc_host_project.host.project
  service_project = "service-project-id"

  # Ensure host is enabled before linking service project
  depends_on = [google_compute_shared_vpc_host_project.host]
}

//subnets
resource "google_compute_subnetwork" "default" {
  name                     = "sub-1"
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.0.0.0/28"
  region                   = "asia-south1"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "default1" {
  name                     = "sub-2"
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.0.0.16/28"
  region                   = "asia-south2"
  private_ip_google_access = true
}

# custom route

resource "google_compute_route" "custom" {
  name             = "custom-route"
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.vpc.name
  next_hop_gateway = "default-internet-gateway" # boundary where your Private VPC meets the Public Internet. Pre-defined by Google
  priority         = 1000
}

// Cloud Router
resource "google_compute_router" "router" {
  name    = "router"
  network = google_compute_network.vpc.id
  region  = "asia-south1"
}

// Cloud NAT

resource "google_compute_router_nat" "nat" {
  name                               = "nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES" # or list of subnets
}

// LB setup - *****************Client → Forwarding Rule → Proxy → URL Map → Backend Service → (healthy VM via MIG) → response back*****************

// health_check
resource "google_compute_health_check" "http-health-check" {
  name = "http-health-check"

  timeout_sec        = 1
  check_interval_sec = 1

  http_health_check {
    port = 80
  }
}

// Internal TCP/UDP Load Balancer

resource "google_compute_region_health_check" "ilb_health_check" {
  name   = "ilb-health-check"
  region = "asia-south1"

  tcp_health_check {
    port = "80"
  }
}

resource "google_compute_region_backend_service" "ilb_backend" {
  name                  = "ilb-backend"
  region                = "asia-south1"
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_region_health_check.ilb_health_check.id]

  backend {
    group          = google_compute_instance_group_manager.test-mig.instance_group
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "ilb_forwarding_rule" {
  name                  = "ilb-forwarding-rule"
  region                = "asia-south1"
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.default.id
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.ilb_backend.id
  ip_protocol           = "TCP"
  ports                 = ["80"]
  allow_global_access   = false # Ensures only same-region VPC resources reach it
}

// Firewall rule to allow health checks and internal traffic to the ILB backends
module "allow_ilb_traffic" {
  source   = "./modules/firewall"
  name     = "allow-ilb-traffic"
  network  = google_compute_network.vpc.name
  protocol = "tcp"
  ports    = ["800"]
  # Source ranges: VPC CIDR + Google Health Check Probers
  source_ranges = ["10.0.0.0/24", "130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["http"]
}

// Test VM to verify internal connectivity
resource "google_compute_instance" "ilb_client_test" {
  name         = "ilb-client-test"
  machine_type = "e2-micro"
  zone         = "asia-south1-a"

  boot_disk {
    initialize_params { image = "debian-cloud/debian-11" }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.default.id
  }
}

// Latency and Throughput Test VM - Region 1
resource "google_compute_instance" "perf_test_south1" {
  name         = "perf-test-south1"
  machine_type = "e2-micro"
  zone         = "asia-south1-a"
  tags         = ["ssh", "iperf"]

  boot_disk {
    initialize_params { image = "debian-cloud/debian-11" }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.default.id
  }

  metadata_startup_script = "apt-get update && apt-get install -y iputils-ping traceroute iperf3"
}

// Latency and Throughput Test VM - Region 2
resource "google_compute_instance" "perf_test_south2" {
  name         = "perf-test-south2"
  machine_type = "e2-micro"
  zone         = "asia-south2-a"
  tags         = ["ssh", "iperf"]

  boot_disk {
    initialize_params { image = "debian-cloud/debian-11" }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.default1.id
  }

  metadata_startup_script = "apt-get update && apt-get install -y iputils-ping traceroute iperf3"
}

// Firewall rule for iperf3 traffic
resource "google_compute_firewall" "allow_iperf" {
  name    = "allow-iperf"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["5201"] # default listening port for iperf3
  }

  source_ranges = ["10.0.0.0/8"]
  target_tags   = ["iperf"]
}

// backend_service (virtual machines that will serve traffic for load balancing)
resource "google_compute_backend_service" "backend" {
  name          = "backend"
  protocol      = "HTTP"
  port_name     = "http"
  health_checks = [google_compute_health_check.http-health-check.self_link]
  enable_cdn    = true # caches response at Nearest Google Edge (CDN)

  backend {
    group = google_compute_instance_group_manager.test-mig.instance_group // returns instanve group we do not need MIG so no id or self_link
  }
}

resource "google_compute_url_map" "url_map" {
  name            = "url-map"
  default_service = google_compute_backend_service.backend.id
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "http-proxy"
  url_map = google_compute_url_map.url_map.id
}

resource "google_compute_global_address" "lb_ip" {
  name = "lb-ip"
}

resource "google_compute_global_forwarding_rule" "http_rule" {
  name         = "http-forwarding-rule"
  target       = google_compute_target_http_proxy.http_proxy.id
  port_range   = "80"
  network_tier = "STANDARD" # PREMIUM: Traffic stays on Google’s global private backbone. STANDARD: Traffic uses the public internet for part of the path
  ip_address   = google_compute_global_address.lb_ip.address
}

// FW_ssh
module "ssh" {
  source        = "./modules/firewall"
  name          = "allow-ssh"
  network       = google_compute_network.vpc.name
  ports         = ["22"]
  source_ranges = ["0.0.0.0/0", "35.240.159.169"] // Public IP address: curl ifconfig.me
  target_tags   = ["ssh"]
  protocol      = "tcp"
}

// Cloud DNS
resource "google_dns_managed_zone" "public_zone" {
  name        = "example-zone"
  dns_name    = "example.com."
  description = "Public DNS zone"
  visibility  = "public"
}

resource "google_dns_record_set" "a_record" {
  name         = "www.${google_dns_managed_zone.public_zone.dns_name}"
  managed_zone = google_dns_managed_zone.public_zone.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb_ip.address] #Resource Record Data strings. It represents the actual value(s) of a DNS record.
}

// Private DNS Zone for Internal Resolution
resource "google_dns_managed_zone" "private_zone" {
  name        = "internal-zone"
  dns_name    = "internal.gcp."
  description = "Private DNS zone for internal VPC resolution"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
}

resource "google_dns_record_set" "internal_vm_record" {
  name         = "nginx.${google_dns_managed_zone.private_zone.dns_name}"
  managed_zone = google_dns_managed_zone.private_zone.name
  type         = "A"
  ttl          = 300
  rrdatas      = [module.linux_vm.ip]
}

// FW_rdp
module "rdp" {
  source        = "./modules/firewall"
  name          = "allow-rdp"
  network       = google_compute_network.vpc.name
  ports         = ["3389"]
  target_tags   = ["rdp"]
  source_ranges = ["0.0.0.0/0"]
  protocol      = "tcp"
}

// FW_http
module "http" {
  source        = "./modules/firewall"
  name          = "allow-http"
  network       = google_compute_network.vpc.name
  target_tags   = ["http"]
  ports         = ["80"]
  source_ranges = ["0.0.0.0/0"]
  protocol      = "tcp"
}

// --- Hub-and-Spoke Topology (VPC Peering) ---

# Spoke VPC-A
resource "google_compute_network" "vpc_a" {
  name                    = "spoke-a"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet_a" {
  name                     = "sub-a"
  ip_cidr_range            = "10.1.0.0/24"
  region                   = "asia-south1"
  network                  = google_compute_network.vpc_a.id
  private_ip_google_access = true
}

# Spoke VPC-B
resource "google_compute_network" "vpc_b" {
  name                    = "spoke-b"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet_b" {
  name                     = "sub-b"
  ip_cidr_range            = "10.2.0.0/24"
  region                   = "asia-south1"
  network                  = google_compute_network.vpc_b.id
  private_ip_google_access = true
}

# Peering: Hub <-> Spoke A
resource "google_compute_network_peering" "hub_to_spoke_a" {
  name         = "hub-to-spoke-a"
  network      = google_compute_network.vpc.id
  peer_network = google_compute_network.vpc_a.id
}

resource "google_compute_network_peering" "spoke_a_to_hub" {
  name         = "spoke-a-to-hub"
  network      = google_compute_network.vpc_a.id
  peer_network = google_compute_network.vpc.id
}

# Peering: Hub <-> Spoke B
resource "google_compute_network_peering" "hub_to_spoke_b" {
  name         = "hub-to-spoke-b"
  network      = google_compute_network.vpc.id
  peer_network = google_compute_network.vpc_b.id
}

# --- Hub VPN Gateway ---
resource "google_compute_ha_vpn_gateway" "hub_gateway" {
  name    = "hub-vpn-gateway"
  network = google_compute_network.vpc.id
  region  = "asia-south1"
}

// VPN and Tunelling

# --- VPC A SIDE ---

resource "google_compute_ha_vpn_gateway" "ha_gateway_a" {
  name    = "vpn-gateway-a"
  network = google_compute_network.vpc_a.id
  region  = "asia-south1"
}

# --- VPC B SIDE ---

resource "google_compute_ha_vpn_gateway" "ha_gateway_b" {
  name    = "vpn-gateway-b"
  network = google_compute_network.vpc_b.id
  region  = "asia-south1"
}

# --- TUNNEL FROM HUB TO SPOKE A ---

resource "google_compute_vpn_tunnel" "hub_to_spoke_a" {
  name                  = "hub-to-spoke-a-vpn"
  region                = "asia-south1"
  vpn_gateway           = google_compute_ha_vpn_gateway.hub_gateway.id
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.ha_gateway_a.id
  shared_secret         = "a_very_secret_key"
  router                = google_compute_router.router.name
  vpn_gateway_interface = 0
}

# --- TUNNEL FROM SPOKE A TO HUB ---

resource "google_compute_vpn_tunnel" "spoke_a_to_hub" {
  name                  = "spoke-a-to-hub-vpn"
  region                = "asia-south1"
  vpn_gateway           = google_compute_ha_vpn_gateway.ha_gateway_a.id
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.hub_gateway.id
  shared_secret         = "a_very_secret_key"
  router                = google_compute_router.router_a.name
  vpn_gateway_interface = 0
}

# --- Cloud Routers for BGP Exchange ---

resource "google_compute_router" "router_a" {
  name    = "router-a"
  network = google_compute_network.vpc_a.id
  region  = "asia-south1"
  bgp {
    asn = 64514
  }
}

resource "google_compute_router" "router_b" {
  name    = "router-b"
  network = google_compute_network.vpc_b.id
  region  = "asia-south1"
  bgp {
    asn = 64515
  }
}

###########   COMPUTE

// linux VM
module "linux_vm" {
  source         = "./modules/vm"
  name           = "nginx"
  network        = google_compute_network.vpc.id
  subnetwork     = google_compute_subnetwork.default.id
  image          = "debian-cloud/debian-11"
  target_tags    = ["ssh", "http"]
  startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx

    # format + mount disk
    if ! blkid /dev/disk/by-id/google-data-disk; then
    mkfs.ext4 /dev/disk/by-id/google-data-disk
    fi
        mkdir -p /data
        mount /dev/disk/by-id/google-data-disk /data

    # persist after reboot
    echo '/dev/disk/by-id/google-data-disk /data ext4 defaults 0 0' >> /etc/fstab
    EOF
}

// windows VM
module "windows_vm" {
  source      = "./modules/vm"
  name        = "winvm"
  network     = google_compute_network.vpc.id
  subnetwork  = google_compute_subnetwork.default1.id
  image       = "windows-cloud/windows-server-2025-dc-v20260414"
  target_tags = ["rdp", "http"]
  metadata = {
    windows-startup-script-ps1 = <<-EOF
    <powershell>
    Install-WindowsFeature -Name Web-Server

    Set-Content -Path "C:\\inetpub\\wwwroot\\index.html" -Value "Hello from IIS"

    Start-Service W3SVC
    </powershell>
  EOF
  }
}

// SS of linux VM
resource "google_compute_snapshot" "bd_ss" {
  name        = "boot-snapshot"
  source_disk = module.linux_vm.boot_disk
}

// PD from SS
resource "google_compute_disk" "backup_disk" {
  name = "backup-disk"
  // id ≈ self_link
  snapshot = google_compute_snapshot.bd_ss.self_link
}

// SS backup VM
resource "google_compute_instance" "nginx-backup" {
  name         = "nginx-backup"
  machine_type = "e2-micro"

  boot_disk {
    source = google_compute_disk.backup_disk.id
  }

  network_interface {
    network = google_compute_network.vpc.id
    #access_config {} # gives external IP
  }
}

// template
resource "google_compute_instance_template" "mig_template" {
  name         = "mig-template"
  machine_type = "e2-micro"

  disk {
    source_image = "debian-cloud/debian-11"
    boot         = true
  }

  network_interface {
    network = google_compute_network.vpc.self_link
    #access_config {
    #}
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    EOF
}

// MIG from template
resource "google_compute_instance_group_manager" "test-mig" {
  name               = "test-mig"
  base_instance_name = "mig-vm"
  zone               = "asia-south1-a"
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.mig_template.self_link
  }

  named_port {
    name = "http"
    port = 80
  }
}

// Autoscaler
resource "google_compute_autoscaler" "foobar" {
  name   = "scale"
  target = google_compute_instance_group_manager.test-mig.self_link

  autoscaling_policy {
    min_replicas = 1
    max_replicas = 2

    cpu_utilization {
      target = 0.5
    }
  }
}

// regional cluster with NAP

resource "google_container_cluster" "primary" {
  name                     = "my-gke-cluster"
  location                 = "asia-south1"
  remove_default_node_pool = true
  initial_node_count       = 1 // GKE needs at least one node to create the cluster initially.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  cluster_autoscaling {
    enabled = true

    resource_limits {
      resource_type = "cpu"
      minimum       = 1
      maximum       = 5
    }
    autoscaling_profile = "BALANCED"
  }
}

//Nodepool with auto scaling

resource "google_container_node_pool" "default" {
  name     = "default"
  location = "asia-south1"
  cluster  = google_container_cluster.primary.name

  node_config {
    machine_type = "e2-micro"
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  initial_node_count = 1
}

// NP2
resource "google_container_node_pool" "Medium" {
  name     = "Medium"
  location = "asia-south1"
  cluster  = google_container_cluster.primary.name

  node_config {
    machine_type = "e2-medium"

    taint {
      key    = "workload"
      value  = "medium"
      effect = "NO_SCHEDULE"
    }
  }


  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  initial_node_count = 1
}

//LBM
resource "google_logging_metric" "lbm" {
  name   = "log-based-metric"
  filter = "resource.type=gce_instance AND severity>=ERROR"
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

// LBM based Alert Policy
resource "google_monitoring_alert_policy" "lbm_alert" {
  display_name = "LBM-Alert"
  combiner     = "OR"

  conditions {
    display_name = "Error-logs"

    condition_threshold {
      filter = "metric.type=\"logging.googleapis.com/user/log-based-metric\" AND resource.type=\"gce_instance\""

      comparison      = "COMPARISON_GT"
      threshold_value = 5

      duration = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }
}

//Kubernetes provider with OAuth2 access token
# Get current authenticated identity (gcloud login or service account)
data "google_client_config" "default" {}

# Fetch existing GKE cluster details
data "google_container_cluster" "cluster" {
  name     = "my-gke-cluster"
  location = "asia-south1"
}

//nginx K8s deployment
resource "kubernetes_deployment" "example" {
  metadata {
    name = "example"
    labels = {
      test = "MyExampleApp"
    }
  }

  spec {
    replicas = 3

    strategy {
      type = "RollingUpdate" // Rolling update

      rolling_update {
        max_surge       = 1
        max_unavailable = 1
      }
    }

    selector {
      match_labels = {
        test = "MyExampleApp"
      }
    }

    template {
      metadata {
        labels = {
          test = "MyExampleApp"
        }
      }

      spec {
        node_selector = {
          "cloud.google.com/gke-nodepool" = "Medium"
        }

        toleration {
          key      = "workload"
          operator = "Equal"
          value    = "medium"
          effect   = "NO_SCHEDULE" // Pods that do NOT tolerate this taint will NOT be scheduled here.
        }

        volume {
          name = "nginx-storage"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nginx_pvc.metadata[0].name
          }
        }


        container {
          name  = "nginx"
          image = "nginx:1.25"

          resources {
            requests = {
              cpu    = "250m"
              memory = "128Mi"
            }

            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "nginx-storage"
            mount_path = "/data"
          }

        }
      }
    }
  }
}

// PVC
resource "kubernetes_persistent_volume_claim" "nginx_pvc" {
  metadata {
    name = "nginx-pvc"
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "5Gi"
      }
    }

    storage_class_name = "standard"
  }
}

// LB/ internal LB service
resource "kubernetes_service" "example_lb" {
  metadata {
    name = "terraform-example-lb"

    /* Internal LB annotation
     annotations = {
      "cloud.google.com/load-balancer-type" = "Internal"
    }
    */
  }

  spec {
    selector = {
      test = "MyExampleApp" # must match pod labels
    }

    port {
      port        = 80 # frontend port on LB
      target_port = 80 # container port (User → External IP:80 (Load Balancer frontend) → NodePort:30xxx (on GKE nodes) → Pod:80 (target_port)
    }

    type = "LoadBalancer"
  }
}

/* ClusterIP service
1. debug container on Cluster: kubectl run debug --rm -it --image=curlimages/curl -- sh
2. Get clusterIP: kubectl get svc app-internal
3. curl http://<CLUSTER-IP>
*/
resource "kubernetes_service" "internal" {
  metadata {
    name = "app-internal"
  }

  spec {
    selector = {
      test = "MyExampleApp"
    }

    port {
      port        = 80
      target_port = 80
    }

    type = "ClusterIP"
  }
}

// Migrate App from VM to VM

resource "terraform_data" "migrate_app" {
  # Replacement for depends_on - triggers if these resources change
  input = { //Without input, your script wouldn't have the updated IDs to work with during the execution.
    source_id = module.linux_vm.id
    dest_id   = google_compute_instance.nginx-backup.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e
      SOURCE_VM="nginx"
      DEST_VM="nginx-backup"
      ZONE="asia-south1-a"

      echo "Starting migration from $SOURCE_VM to $DEST_VM..."

      # 1. Export data/config from Source VM
      gcloud compute ssh "$SOURCE_VM" --zone="$ZONE" --command="sudo tar -czf /tmp/app_backup.tar.gz -C /var/www/html ."

      # 2. Transfer backup
      gcloud compute scp "$SOURCE_VM":/tmp/app_backup.tar.gz ./app_backup.tar.gz --zone="$ZONE"
      gcloud compute scp ./app_backup.tar.gz "$DEST_VM":/tmp/app_backup.tar.gz --zone="$ZONE"

      # 3. Restore on Destination VM
      gcloud compute ssh "$DEST_VM" --zone="$ZONE" --command="sudo tar -xzf /tmp/app_backup.tar.gz -C /var/www/html && sudo systemctl restart nginx"

      # 4. Validate Uptime/Health
      DEST_IP=$(gcloud compute instances describe "$DEST_VM" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
      
      echo "Validating uptime for $DEST_IP..."
      STATUS=$(curl -s -o /dev/null -w "%%{http_code}" http://"$DEST_IP")

      if [ "$STATUS" -eq 200 ]; then
        echo "Migration Successful. App is UP on $DEST_VM (Status: $STATUS)"
        rm ./app_backup.tar.gz
      else
        echo "Migration Validation Failed. Status: $STATUS"
        exit 1
      fi
    EOT
  }

  lifecycle { # Without lifecycle, Terraform would simply update the metadata in your state file silently and never actually run your script after the initial deployment.
    replace_triggered_by = [
      terraform_data.migrate_app.input
    ]
  }
}


resource "google_compute_instance" "for" {

  for_each = tomap({
    key1 = "e2-micro"
    key2 = "e2-medium"
  })
  name         = each.key
  machine_type = each.value

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.default.id
    access_config {

    }

  }
  dynamic "tags" {
    for_each = var.tags
    content {
      items = tags.value
    }
    
  }
}