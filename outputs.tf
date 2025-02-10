output "ami" {
  value = data.aws_ami.ubuntu.id
}

output "instance_details" {
  value = [
    for instance in data.aws_instance.fleet : {
      id            = instance.id
      public_ip     = instance.public_ip
      private_ip    = instance.private_ip
      public_dns    = instance.public_dns
      instance_type = instance.instance_type
      ssh_command   = "ssh -i ${local_sensitive_file.deployment_key.filename} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${instance.public_dns}"
      role          = index(data.aws_instance.fleet, instance) == length(data.aws_instance.fleet) - 1 ? "client" : "server"
    }
  ]
}
