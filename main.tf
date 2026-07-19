locals {
  personal_practice_manifest_path = "${path.module}/local-practice/personal-practice.yaml"
  personal_practice_manifest      = fileexists(local.personal_practice_manifest_path) ? file(local.personal_practice_manifest_path) : ""
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_instance" "cka" {
  name         = var.instance_name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["cka-practice"]
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"

    access_config {}
  }

  metadata = {
    enable-oslogin             = "TRUE"
    startup-script             = file("${path.module}/scripts/bootstrap-kubernetes.sh")
    personal-practice-manifest = local.personal_practice_manifest
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  depends_on = [google_project_service.compute]
}
