output "boot_disk" {
  value = google_compute_instance.linux_vm.boot_disk[0].source
}

output "id" {
  value = google_compute_instance.linux_vm.id
}

output "ip"{
  value = google_compute_instance.linux_vm.network_interface[0].network_ip
}
