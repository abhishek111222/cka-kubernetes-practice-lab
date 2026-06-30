variable "project_id" {
  description = "The billing-enabled GCP project in which resources will be created."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must not be empty."
  }
}

variable "region" {
  description = "The GCP region for regional resources."
  type        = string
  default     = "europe-west2"
}

variable "zone" {
  description = "The GCP zone for the VM. It must belong to the selected region."
  type        = string
  default     = "europe-west2-a"
}

variable "instance_name" {
  description = "Name of the practice VM."
  type        = string
  default     = "abhis-cka-vm"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.instance_name))
    error_message = "instance_name must be a valid GCP resource name using lowercase letters, digits, and hyphens."
  }
}

variable "machine_type" {
  description = "Compute Engine machine type. e2-small provides 2 shared-core vCPUs and 2 GB RAM."
  type        = string
  default     = "e2-small"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GiB."
  type        = number
  default     = 30

  validation {
    condition     = var.boot_disk_size_gb >= 20
    error_message = "boot_disk_size_gb must be at least 20 GiB."
  }
}

variable "labels" {
  description = "Labels applied to the VM."
  type        = map(string)
  default = {
    environment = "cka-practice"
    managed_by  = "terraform"
  }
}
