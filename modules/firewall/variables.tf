variable "name" {
  type = string
}

variable "network" {
  type = string
}

variable "ports" {
  type = list(string)
}

variable "source_ranges" {
  type = list(string)
}

variable "protocol" {
  type = string
}

variable "target_tags" {
  type = list(string)
}