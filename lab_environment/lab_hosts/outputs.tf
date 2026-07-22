###############################################################################
# IO-108 -- lab_hosts / outputs.tf
###############################################################################

output "lab_hosts" {
  description = "student_id -> lab host instance id."
  value       = { for id, inst in aws_instance.lab_host : id => inst.id }
}

output "connect_hint" {
  description = "How each student reaches their host (SSM Session Manager, no SSH)."
  value = join("\n", concat(
    ["Connect via SSM (console: Systems Manager > Session Manager > Start session, pick your host; or CLI below):"],
    [for id, inst in aws_instance.lab_host : "  ${id}: aws ssm start-session --target ${inst.id} --region ${var.region}"]
  ))
}
