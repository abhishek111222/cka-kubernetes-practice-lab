locals {
  personal_practice_manifest_path = "${path.module}/local-practice/personal-practice.yaml"
  personal_practice_manifest      = fileexists(local.personal_practice_manifest_path) ? file(local.personal_practice_manifest_path) : ""
  personal_practice_script_path   = "${path.module}/local-practice/personal-practice.sh"
  personal_practice_script        = fileexists(local.personal_practice_script_path) ? file(local.personal_practice_script_path) : ""
  control_plane_name              = "${var.instance_name}-control-plane"
  worker_names                    = [for index in range(var.worker_count) : "${var.instance_name}-worker-${index + 1}"]
  control_plane_machine_type      = coalesce(var.control_plane_machine_type, var.machine_type)
  worker_machine_type             = coalesce(var.worker_machine_type, var.machine_type)
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_firewall" "cka_internal" {
  name    = "${var.instance_name}-internal"
  network = "default"

  allow {
    protocol = "all"
  }

  source_tags = ["cka-practice"]
  target_tags = ["cka-practice"]

  depends_on = [google_project_service.compute]
}

resource "google_compute_instance" "control_plane" {
  name         = local.control_plane_name
  zone         = var.zone
  machine_type = local.control_plane_machine_type
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
    personal-practice-script   = local.personal_practice_script
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

  depends_on = [google_compute_firewall.cka_internal]
}

resource "google_compute_instance" "worker" {
  count        = var.worker_count
  name         = local.worker_names[count.index]
  zone         = var.zone
  machine_type = local.worker_machine_type
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
    enable-oslogin     = "TRUE"
    startup-script     = file("${path.module}/scripts/bootstrap-worker.sh")
    control-plane-ip   = google_compute_instance.control_plane.network_interface[0].network_ip
    control-plane-name = google_compute_instance.control_plane.name
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

  depends_on = [google_compute_instance.control_plane]
}
