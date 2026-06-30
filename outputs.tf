output "instance_name" {
  description = "Name of the created VM."
  value       = google_compute_instance.cka.name
}

output "project_id" {
  description = "GCP project containing the practice environment."
  value       = var.project_id
}

output "instance_zone" {
  description = "Zone containing the VM."
  value       = google_compute_instance.cka.zone
}

output "external_ip" {
  description = "Public IPv4 address assigned to the VM."
  value       = google_compute_instance.cka.network_interface[0].access_config[0].nat_ip
}

output "internal_ip" {
  description = "Private IPv4 address assigned to the VM."
  value       = google_compute_instance.cka.network_interface[0].network_ip
}

output "ssh_command" {
  description = "Command for connecting through gcloud and OS Login."
  value       = "gcloud compute ssh ${google_compute_instance.cka.name} --project ${var.project_id} --zone ${var.zone}"
}

output "cluster_check_command" {
  description = "Command to check the Kubernetes node after connecting to the VM."
  value       = "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide"
}

output "bootstrap_log_command" {
  description = "Command to follow Kubernetes bootstrap progress after connecting to the VM."
  value       = "sudo tail -f /var/log/cka-bootstrap.log"
}
