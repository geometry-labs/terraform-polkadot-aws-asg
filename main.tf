data "aws_region" "this" {}

module "label" {
  source = "github.com/robc-io/terraform-null-label.git?ref=0.16.1"
  tags = {
    NetworkName = var.network_name
    Owner       = var.owner
    Terraform   = true
    VpcType     = "main"
  }

  environment = var.environment
  namespace   = var.namespace
  stage       = var.stage
}

resource "null_resource" "requirements" {
  triggers = {
    time = timestamp()
  }

  provisioner "local-exec" {
    command = "ansible-galaxy install -r ${path.module}/ansible/requirements.yml"
  }
}

module "packer" {
  create = var.create

  source = "github.com/insight-infrastructure/terraform-aws-packer-ami.git?ref=master"

  packer_config_path = "${path.module}/packer.json"
  timestamp_ui       = true
  vars = {
    id = module.label.id,
    aws_region  = data.aws_region.this.name,
    module_path = path.module,
    node_exporter_user : var.node_exporter_user,
    node_exporter_password : var.node_exporter_password,
    chain : var.chain,
    ssh_user : var.ssh_user,
    project : var.project,
    polkadot_binary_url : var.polkadot_client_url,
    polkadot_binary_checksum : "sha256:${var.polkadot_client_hash}",
    node_exporter_binary_url : var.node_exporter_url,
    node_exporter_binary_checksum : "sha256:${var.node_exporter_hash}",
    polkadot_restart_enabled : true,
    polkadot_restart_minute : "50",
    polkadot_restart_hour : "10",
    polkadot_restart_day : "1",
    polkadot_restart_month : "*",
    polkadot_restart_weekday : "*",
    telemetry_url : var.telemetry_url,
    logging_filter : var.logging_filter,
    relay_ip_address : var.relay_node_ip,
    relay_p2p_address : var.relay_node_p2p_address,
    consul_datacenter : data.aws_region.this.name,
    consul_enabled : var.consul_enabled,
    prometheus_enabled : var.prometheus_enabled,
    retry_join : "\"provider=aws tag_key='k8s.io/cluster/${var.cluster_name}' tag_value=owned\""
  }
}

// Was having issues in some regions so put in a sleep to fix
resource "null_resource" "wait" {
  triggers = {
    time = timestamp()
  }

  provisioner "local-exec" {
    command = "sleep 10"
  }

  depends_on = [module.packer]
}

data "aws_ami" "packer" {
  most_recent = true

  filter {
    name   = "tag:Id"
    values = [module.label.id]
  }

  owners = ["self"]

  depends_on = [module.packer.packer_command, null_resource.wait]
}

module "user_data" {
  source = "github.com/insight-w3f/terraform-polkadot-user-data.git?ref=master"
  cloud_provider = "aws"
  type = "library"
  consul_enabled      = var.consul_enabled
  prometheus_enabled  = var.prometheus_enabled
  prometheus_user     = var.node_exporter_user
  prometheus_password = var.node_exporter_password
}

resource "aws_key_pair" "this" {
  count      = var.key_name == "" ? 1 : 0
  public_key = var.public_key
}

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 3.0"

  spot_price = "1"

  name    = module.label.id
  lc_name = module.label.id

  user_data = module.user_data.user_data

  key_name = var.key_name == "" ? join("", aws_key_pair.this.*.key_name) : var.key_name

  image_id = data.aws_ami.packer.id

  instance_type   = "c4.large"
  security_groups = var.security_groups
  iam_instance_profile = aws_iam_instance_profile.this.name

  root_block_device = [
    {
      volume_size = "256"
      volume_type = "gp2"
    }
  ]

  vpc_zone_identifier = var.subnet_ids

  health_check_type = "EC2"
  //  TODO Verify ^^
  min_size                  = 1
  max_size                  = 3
  desired_capacity          = 1
  wait_for_capacity_timeout = 0

  tags_as_map = module.label.tags
}

resource "aws_autoscaling_attachment" "this" {
  autoscaling_group_name = module.asg.this_autoscaling_group_id
  alb_target_group_arn   = var.lb_target_group_arn
}
