output "jumphost_public_ip" {
  description = "Elastic IP address of the jumphost."
  value       = aws_eip.jumphost.public_ip
}

output "jumphost_ssh_command" {
  description = "Ready-to-use SSH command. Save the private key from jumphost_private_key_pem to jumphost-key.pem (chmod 600) before use."
  value       = "ssh -i jumphost-key.pem ec2-user@${aws_eip.jumphost.public_ip}"
  sensitive   = true
}

output "jumphost_private_key_pem" {
  description = "RSA private key PEM. Retrieve once and store securely — this is the only time it is exposed."
  value       = tls_private_key.jumphost.private_key_pem
  sensitive   = true
}

output "jumphost_instance_id" {
  description = "EC2 instance ID of the jumphost."
  value       = aws_instance.jumphost.id
}

output "jumphost_security_group_id" {
  description = "Security group ID attached to the jumphost."
  value       = aws_security_group.jumphost.id
}
