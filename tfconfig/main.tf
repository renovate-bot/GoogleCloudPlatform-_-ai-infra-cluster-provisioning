/**
  * Copyright 2022 Google LLC
  *
  * Licensed under the Apache License, Version 2.0 (the "License");
  * you may not use this file except in compliance with the License.
  * You may obtain a copy of the License at
  *
  *      http://www.apache.org/licenses/LICENSE-2.0
  *
  * Unless required by applicable law or agreed to in writing, software
  * distributed under the License is distributed on an "AS IS" BASIS,
  * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  * See the License for the specific language governing permissions and
  * limitations under the License.
  */

locals {
  trimmed_net_config = lower(trimspace(var.network_config))
  primary_network    = coalesce(one(module.new_primary_network), one(module.default_primary_network))
}
module "default_primary_network" {
  count      = local.trimmed_net_config != "new_network" ? 1 : 0
  source     = "github.com/GoogleCloudPlatform/hpc-toolkit//modules/network/pre-existing-vpc//?ref=c1f4a44d92e775baa8c48aab6ae28cf9aee932a1"
  project_id = var.project_id
  region     = var.region
}

module "new_primary_network" {
  count           = local.trimmed_net_config == "new_network" ? 1 : 0
  source          = "github.com/GoogleCloudPlatform/hpc-toolkit//modules/network/vpc//?ref=c1f4a44d92e775baa8c48aab6ae28cf9aee932a1"
  project_id      = var.project_id
  region          = var.region
  deployment_name = var.deployment_name
}

module "multi-nic-network" {
  count           = local.trimmed_net_config == "multi_nic_network" ? 1 : 0
  source          = "./modules/multi-nic-network"
  project_id      = var.project_id
  region          = var.region
  deployment_name = var.deployment_name
}

__REPLACE_GCS_BUCKET_MOUNT_MODULE__

module "startup" {
  source          = "github.com/GoogleCloudPlatform/hpc-toolkit//modules/scripts/startup-script/?ref=1b1cdb09347433ecdb65488989f70135e65e217b"
  project_id      = var.project_id
  runners = [{
    destination = "install_cloud_ops_agent.sh"
    source      = "/usr/install_cloud_ops_agent.sh"
    type        = "shell"
__REPLACE_FILES__
__REPLACE_STARTUP_SCRIPT__
  }__REPLACE_GCS_BUCKET_MOUNT_SCRIPT__]
  labels          = merge(var.labels, { ghpc_role = "scripts",})
  deployment_name = var.deployment_name
  gcs_bucket_path = var.gcs_bucket_path
  region          = var.region
}

module "compute-vm-1" {
  source               = "./modules/vm-instance-group"
  subnetwork_self_link = local.primary_network.subnetwork_self_link
  service_account = {
    email  = var.service_account
    scopes = ["cloud-platform"]
  }
  instance_count    = var.instance_count
  project_id        = var.project_id
  disk_size_gb      = var.disk_size_gb
  disk_type         = var.disk_type
  network_self_link = local.primary_network.network_self_link
  placement_policy = {
    availability_domain_count = null
    collocation               = "COLLOCATED"
    vm_count                  = var.instance_count
  }
  instance_image      = var.instance_image
  on_host_maintenance = "TERMINATE"
  machine_type        = var.machine_type
  zone                = var.zone
  region              = var.region
  startup_script      = module.startup.startup_script
  metadata = merge(var.metadata, { VmDnsSetting = "ZonalPreferred", enable-oslogin = "TRUE", install-nvidia-driver = "True", proxy-mode="project_editors", })
  labels      = merge(var.labels, { aiinfra_role = "compute",})
  name_prefix = var.name_prefix
  guest_accelerator = [{
    count = var.gpu_per_vm
    type  = var.accelerator_type
  }]
  deployment_name = var.deployment_name
  network_interfaces = local.trimmed_net_config == "multi_nic_network" ? module.multi-nic-network[0].multi_network_interface : []
  depends_on = [
    local.primary_network,
    module.multi-nic-network
  ]
}

/*
* The dashboard needs to include GPU metrics from new ops agent.
*/
module "aiinfra-default-dashboard" {
  source          = "github.com/GoogleCloudPlatform/hpc-toolkit//modules/monitoring/dashboard/?ref=c1f4a44d92e775baa8c48aab6ae28cf9aee932a1"
  project_id      = var.project_id
  deployment_name = var.deployment_name
  base_dashboard  = "Empty"
  title           = "AI Accelerator Experience Dashboard"
}
