#------------------------------------------------------------------------------
# Collect necessary data
#------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnet_ids" "this" {
  vpc_id = data.aws_vpc.this.id
  tags = {
    Name = "*${var.subnet_filter}*"
  }
}

data "aws_ami" "latest_ecs_ami" {
  most_recent = true
  owners      = ["591542846629"] # AWS
  filter {
    name   = "name"
    values = ["*amazon-ecs-optimized"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "template_file" "user_data" {
  template = <<EOF
Content-Type: multipart/mixed; boundary="==BOUNDARY=="
MIME-Version: 1.0

--==BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
# Set any ECS agent configuration options
echo "ECS_CLUSTER=$${ecs_cluster_name}" >> /etc/ecs/ecs.config

--==BOUNDARY==--

EOF

  vars = {
    ecs_cluster_name = aws_ecs_cluster.this.name
  }
}

#------------------------------------------------------------------------------
# Local Values
#------------------------------------------------------------------------------
locals {
  subnet_ids_string = join(",", data.aws_subnet_ids.this.ids)
  subnet_ids_list   = split(",", local.subnet_ids_string)
}

locals {
  ecs_security_groups = tolist(aws_security_group.this.id)
}

locals {
  tags_asg_format = null_resource.tags_as_list_of_maps.*.triggers
}

resource "null_resource" "tags_as_list_of_maps" {
  count = length(keys(var.tags))

  triggers = {
    "key"                 = keys(var.tags)[count.index]
    "value"               = values(var.tags)[count.index]
    "propagate_at_launch" = "true"
  }
}

#------------------------------------------------------------------------------
# Create ECS Cluster
#------------------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = var.ecs_name
  description = "Security Group for ECS cluster"
  vpc_id      = data.aws_vpc.this.id
  ingress {
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }
  egress {
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(
    {
      "Name" = var.ecs_name
    },
    var.tags
  )
}

resource "aws_ecs_cluster" "this" {
  name = var.ecs_name
  tags = merge(
    {
      "Name" = var.ecs_name
    },
    var.tags
  )
}

resource "aws_autoscaling_group" "this" {
  name                      = var.ecs_name
  min_size                  = var.ecs_min_size
  max_size                  = var.ecs_max_size
  desired_capacity          = var.ecs_desired_capacity
  health_check_type         = "EC2"
  health_check_grace_period = 300
  vpc_zone_identifier       = local.subnet_ids_list
  launch_configuration      = aws_launch_configuration.this.name
  lifecycle {
    create_before_destroy = true
  }

  tags = concat(
    [
      {
        key                 = "Name"
        value               = var.ecs_name
        propagate_at_launch = true
      }
    ],
    local.tags_asg_format,
  )
}

resource "aws_launch_configuration" "this" {
  name_prefix                 = "${var.ecs_name}-"
  image_id                    = data.aws_ami.latest_ecs_ami.image_id
  instance_type               = var.ecs_instance_type
  security_groups             = [local.ecs_security_groups]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  key_name                    = var.ecs_key_name
  associate_public_ip_address = var.ecs_associate_public_ip_address
  user_data                   = data.template_file.user_data.rendered

  lifecycle {
    create_before_destroy = true
  }
}

#------------------------------------------------------------------------------
# Create the Instance Profile
#------------------------------------------------------------------------------
resource "aws_iam_instance_profile" "this" {
  name = var.ecs_name
  role = aws_iam_role.this.name
}

resource "aws_iam_role" "this" {
  name               = var.ecs_name
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags = merge(
    {
      "Name" = var.ecs_name
    },
    var.tags
  )
}

resource "aws_iam_role_policy" "this" {
  name   = var.ecs_name
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.policy.json
}

data "aws_iam_policy_document" "policy" {
  statement {
    effect = "Allow"
    actions = [
      "ecs:CreateCluster",
      "ecs:DeregisterContainerInstance",
      "ecs:DiscoverPollEndpoint",
      "ecs:Poll",
      "ecs:RegisterContainerInstance",
      "ecs:StartTelemetrySession",
      "ecs:Submit*",
      "ecs:StartTask",
      "ecs:ListClusters",
      "ecs:DescribeClusters",
      "ecs:RegisterTaskDefinition",
      "ecs:RunTask",
      "ecs:StopTask",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }
  dynamic "statement" {
    for_each = var.ecs_additional_iam_statements
    content {
      effect = lookup(statement.value, "effect", null)
      actions = lookup(statement.value, "actions", null)
      resources = lookup(statement.value, "resources", null)
    }
  }

}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "ecs.amazonaws.com",
        "ec2.amazonaws.com"
      ]
    }
  }
}