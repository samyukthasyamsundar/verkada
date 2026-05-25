output "bastion_public_ip" {
  description = "SSH into this to reach the private network"
  value       = aws_instance.bastion.public_ip
}

output "mgmt_server_private_ip" {
  description = "Private IP of the camera management server"
  value       = aws_instance.mgmt_server.private_ip
}

output "footage_bucket_name" {
  description = "S3 bucket for camera footage backups"
  value       = aws_s3_bucket.footage.bucket
}

output "ssh_command" {
  description = "Command to SSH into the bastion host"
  value       = "ssh -i verkada-key.pem ec2-user@${aws_instance.bastion.public_ip}"
}
