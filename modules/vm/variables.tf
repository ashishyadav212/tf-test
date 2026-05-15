variable "name" {
  type = string
}

variable "network" {
  type = string
}

variable "image" {
  type = string
}

variable "startup_script" {
  type    = string
  default = null
}

variable "metadata" {
  type    = map(string)  // map is a key, value pair 
  default = {}
}

variable "disk_size" {
  type    = number
  default = 10
}

variable "subnetwork" {
  type = string
}

variable "target_tags" {
  type = list(string)
}