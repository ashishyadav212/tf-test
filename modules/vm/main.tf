resource "google_compute_instance" "linux_vm"{
    name = var.name
    machine_type = "e2-micro"
    tags = var.target_tags

    boot_disk{
        initialize_params{
            image = var.image
        } 
    }

    network_interface {
    network = var.network
    subnetwork = var.subnetwork
    #access_config {} # gives external IP
  }

metadata_startup_script = var.startup_script
metadata = var.metadata

attached_disk {
  source      = google_compute_disk.data_disk.id
  device_name = "data-disk"
    }
}

resource "google_compute_disk" "data_disk"{
    name = "${var.name}-disk"
    type = "pd-ssd"
    size = var.disk_size
}

