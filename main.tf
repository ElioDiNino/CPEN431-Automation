locals {
  instance_count = 2
  tags = {
    Project    = "CPEN 431"
    Assignment = "A7-11"
  }
}

data "aws_ec2_instance_type" "instance_type" {
  instance_type = var.instance_type
}

data "aws_ami" "ubuntu" {
  # Ref: https://documentation.ubuntu.com/aws/en/latest/aws-how-to/instances/find-ubuntu-images/
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-${var.ubuntu-version}-*-server-*"]
  }

  filter {
    name   = "architecture"
    values = data.aws_ec2_instance_type.instance_type.supported_architectures
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_security_group" "this" {}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv6" {
  security_group_id = aws_security_group.this.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "allow_public_ssh" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "allow_internal_traffic" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "allow_all_udp" {
  # This is unfortunately required by the client and submission server
  security_group_id = aws_security_group.this.id
  cidr_ipv4 = "0.0.0.0/0"
  ip_protocol = "udp"
  from_port = 0
  to_port = 65535
}

resource "aws_vpc_security_group_ingress_rule" "allow_all_tcp" {
  # This is unfortunately required by the client and submission server
  security_group_id = aws_security_group.this.id
  cidr_ipv4 = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port = 0
  to_port = 65535
}

module "aws_key_pair_deployment" {
  source = "terraform-aws-modules/key-pair/aws"

  key_name_prefix       = "deployment-"
  create_private_key    = true
  private_key_algorithm = "ED25519"
}

resource "local_sensitive_file" "deployment_key" {
  content         = "${module.aws_key_pair_deployment.private_key_openssh}\n"
  filename        = "${path.module}/ec2.pem"
  file_permission = "400"
}

resource "aws_launch_template" "this" {
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = data.aws_ec2_instance_type.instance_type.instance_type
  key_name               = module.aws_key_pair_deployment.key_pair_name
  vpc_security_group_ids = [aws_security_group.this.id]
  update_default_version = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price          = var.max_hourly_instance_price
      spot_instance_type = "one-time"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  tag_specifications {
    resource_type = "spot-instances-request"
    tags          = local.tags
  }
}

resource "aws_ec2_fleet" "this" {
  type                = "instant"
  terminate_instances = true

  launch_template_config {
    launch_template_specification {
      launch_template_id = aws_launch_template.this.id
      version            = "$Latest"
    }
  }

  # Blocked by https://github.com/hashicorp/terraform-provider-aws/issues/41237
  # spot_options {
  #   max_total_price          = local.instance_count * var.max_hourly_instance_price
  #   min_target_capacity      = local.instance_count
  #   single_instance_type     = true
  #   single_availability_zone = true
  # }

  target_capacity_specification {
    default_target_capacity_type = "spot"
    spot_target_capacity         = local.instance_count
    total_target_capacity        = local.instance_count
  }
}

data "aws_instance" "fleet" {
  depends_on = [aws_ec2_fleet.this]
  count      = local.instance_count
  # The following works since we are using the "instant" fleet type and so the instance set is available immediately
  instance_id = aws_ec2_fleet.this.fleet_instance_set[0].instance_ids[count.index]
}

resource "null_resource" "configure_instances" {
  count = length(data.aws_instance.fleet.*)

  triggers = {
    instance_id = data.aws_instance.fleet[count.index].id
  }

  connection {
    host        = data.aws_instance.fleet[count.index].public_dns
    user        = "ubuntu"
    private_key = module.aws_key_pair_deployment.private_key_openssh
  }

  provisioner "file" {
    source      = "${path.module}/start.sh"
    destination = "/tmp/start.sh"
  }

  provisioner "file" {
    source      = "${path.module}/server.sh"
    destination = "/tmp/server.sh"
  }

  provisioner "file" {
    source      = "${path.module}/cpen431_pop_2025.pub"
    destination = "/tmp/instructor_key.pub"
  }

  provisioner "file" {
    # Create /tmp/upload on the remote instance and copy the contents of the local upload directory
    source      = "${path.module}/upload"
    destination = "/tmp"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Instances are ready!'",
      "cat /tmp/instructor_key.pub >> /home/ubuntu/.ssh/authorized_keys",
      "echo 'Added instructor key to authorized_keys'",
      "chmod +x /tmp/start.sh",
      # Handle Git on Windows changing line endings
      "sed -i -e 's/\r$//' /tmp/start.sh",
      "/tmp/start.sh setup",
    ]
  }

  provisioner "remote-exec" {
    # Enable network emulation on only the first instance
    inline = count.index == 0 ? [
      "/tmp/start.sh netem-enable",
      "echo 'Network emulation enabled'",
    ] : [
      # An empty command is not allowed in Terraform, so we echo a message
      "echo 'Network emulation not enabled'",
    ]
  }
}
