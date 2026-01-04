variable "project_id" {
  default = "gky100"
}
variable "region" {
  default = "us-west1"
}
variable "zone" {
  default = "us-west1-a"
}
variable "instance_type" {
  default = "e2-medium"
}
variable "instance_name" {
  default = "app-server"
}
variable "google_credentials" {
  type      = string
  sensitive = true
}
