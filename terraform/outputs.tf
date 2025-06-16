output "vpc_id" {
  value = aws_vpc.main.id
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}