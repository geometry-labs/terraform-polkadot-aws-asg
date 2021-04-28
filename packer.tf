#####
# packer
#####
variable "polkadot_client_url" {
  description = "URL to Polkadot client binary"
  type        = string
  default     = "https://github.com/paritytech/polkadot/releases/download/v0.8.29/polkadot"
}

variable "polkadot_client_hash" {
  description = "SHA256 hash of Polkadot client binary"
  type        = string
  default     = "0b27d0cb99ca60c08c78102a9d2f513d89dfec8dbd6fdeba8b952a420cdc9fd2"
}

variable "node_exporter_url" {
  description = "URL to Node Exporter binary"
  type        = string
  default     = "https://github.com/prometheus/node_exporter/releases/download/v0.18.1/node_exporter-0.18.1.linux-amd64.tar.gz"
}

variable "node_exporter_hash" {
  description = "SHA256 hash of Node Exporter binary"
  type        = string
  default     = "b2503fd932f85f4e5baf161268854bf5d22001869b84f00fd2d1f57b51b72424"
}

variable "node_exporter_user" {
  description = "User for node exporter"
  type        = string
  default     = "node_exporter_user"
}

variable "node_exporter_password" {
  description = "Password for node exporter"
  type        = string
  default     = "node_exporter_password"
}

variable "project" {
  description = "Name of the project for node name"
  type        = string
  default     = "project"
}

variable "ssh_user" {
  description = "Username for SSH"
  type        = string
  default     = "ubuntu"
}

variable "default_telemetry_enabled" {
  description = ""
  type        = bool
  default     = true
}

variable "telemetry_url" {
  description = "WSS URL for telemetry"
  type        = string
  default     = ""
}

variable "logging_filter" {
  description = "String for polkadot logging filter"
  type        = string
  default     = "sync=trace,afg=trace,babe=debug"
}

variable "relay_node_ip" {
  description = "Internal IP of Polkadot relay node"
  type        = string
  default     = ""
}

variable "relay_node_p2p_address" {
  description = "P2P address of Polkadot relay node"
  type        = string
  default     = ""
}

variable "consul_enabled" {
  description = "Bool to use when Consul is enabled"
  type        = bool
  default     = false
}

variable "prometheus_enabled" {
  description = "Bool to use when Prometheus is enabled"
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "The name of the k8s cluster"
  type        = string
  default     = ""
}

variable "sync_aws_access_key_id" {
  description = "AWS access key ID for SoT sync"
  type        = string
  default     = ""
}

variable "sync_aws_secret_access_key" {
  description = "AWS access key for SoT sync"
  type        = string
  default     = ""
}

variable "sync_bucket_uri" {
  description = "S3 bucket URI for SoT sync"
  type        = string
  default     = ""
}

variable "packer_build_role_arn" {
  description = "The role arn the packer build should use to build the image."
  type        = string
  default     = ""
}

variable "build_vpc_id" {
  description = "VPC to build the image in. Must have public subnet - Omit if running cluster deployed in in public subnets."
  type        = string
  default     = ""
}

variable "build_subnet_id" {
  description = "The subnet to build the image in.  Must be public - Omit if running cluster deployed in in public subnets. "
  type        = string
  default     = ""
}

resource "null_resource" "requirements" {
  triggers = {
    time = timestamp()
  }

  provisioner "local-exec" {
    command = "ansible-galaxy install -r ${path.module}/ansible/requirements.yml -f"
  }
}

module "packer" {
  source = "github.com/geometry-labs/terraform-packer-build.git?ref=main"

  create = var.create && var.ami_id == ""
  //  packer_config_path = "${path.module}/packer.json" # .pkr.hcl
  packer_config_path = "${path.module}/packer.pkr.hcl"
  timestamp_ui       = true
  vars = {
    vpc_id    = var.build_vpc_id == "" ? local.vpc_id : var.build_vpc_id
    subnet_id = var.build_subnet_id == "" ? local.subnet_ids[0] : var.build_subnet_id

    id                     = local.id
    this_skip_health_check = var.skip_health_check
    network_settings       = jsonencode(local.network_settings)
    aws_region             = data.aws_region.this.name
    module_path            = path.module
    node_exporter_user     = var.node_exporter_user
    node_exporter_password = var.node_exporter_password
    role_arn               = var.packer_build_role_arn
    //    ssh_user                      = var.ssh_user
    project                       = var.project
    instance_count                = "library"
    polkadot_binary_url           = var.polkadot_client_url
    polkadot_binary_checksum      = "sha256:${var.polkadot_client_hash}"
    node_exporter_binary_url      = var.node_exporter_url
    node_exporter_binary_checksum = "sha256:${var.node_exporter_hash}"
    polkadot_restart_enabled      = false
    default_telemetry_enabled     = var.default_telemetry_enabled
    telemetry_url                 = var.telemetry_url
    logging_filter                = var.logging_filter
    consul_datacenter             = data.aws_region.this.name
    consul_enabled                = var.consul_enabled
    prometheus_enabled            = var.prometheus_enabled
    retry_join                    = "provider=aws tag_key=\"k8s.io/cluster/${var.cluster_name}\" tag_value=owned"
    aws_access_key_id             = var.sync_aws_access_key_id
    aws_secret_access_key         = var.sync_aws_secret_access_key
    sync_bucket_uri               = var.sync_bucket_uri
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
    values = [local.id]
  }

  owners = ["self"]

  depends_on = [module.packer.packer_command, null_resource.wait]
}