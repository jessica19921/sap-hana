variable "resource-group" {
  description = "Details of the resource group"
}

variable "subnet-mgmt" {
  description = "Details of the management subnet"
}

variable "nsg-mgmt" {
  description = "Details of the management NSG"
}

variable "storage-bootdiag" {
  description = "Details of the boot diagnostics storage account"
}

variable "output-json" {
  description = "Details of the output JSON"
}

variable "ansible-inventory" {
  description = "Details of the Ansible inventory"
}

variable "random-id" {
  description = "Random hex for creating unique Azure key vault name"
}

locals {
  output-tf = jsondecode(var.output-json.content)

  # Linux jumpbox information
  vm-jump-linux = [
    for jumpbox in var.jumpboxes.linux : jumpbox
    if jumpbox.destroy_after_deploy != "true"
  ]

  # Windows jumpbox information
  vm-jump-win = [
    for jumpbox in var.jumpboxes.windows : jumpbox
  ]

  # RTI information with default count 1
  rti_updated = [
    for jumpbox in var.jumpboxes.linux : merge({ "private_ip_address" = "" }, jumpbox)
    if jumpbox.destroy_after_deploy == "true"
  ]
  rti = length(local.rti_updated) > 0 ? local.rti_updated : [
    {
      "name"                 = "rti",
      "destroy_after_deploy" = "true",
      "size"                 = "Standard_D2s_v3",
      "disk_type"            = "StandardSSD_LRS",
      "os" = {
        "publisher" = "Canonical",
        "offer"     = "UbuntuServer",
        "sku"       = "18.04-LTS"
      },
      "authentication" = {
        "type"     = "key",
        "username" = "azureadm"
      },
      "components" = [
        "ansible"
      ],
      "private_ip_address" = ""
    }
  ]
}
