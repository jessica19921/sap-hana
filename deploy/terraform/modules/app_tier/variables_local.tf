variable "resource-group" {
  description = "Details of the resource group"
}

variable "vnet-sap" {
  description = "Details of the SAP VNet"
}

variable "storage-bootdiag" {
  description = "Details of the boot diagnostic storage device"
}

variable "ppg" {
  description = "Details of the proximity placement group"
}

# Set defaults
locals {
  application_sid          = try(var.application.sid, "HN1")
  enable_deployment        = try(var.application.enable_deployment, false)
  scs_instance_number      = try(var.application.scs_instance_number, "01")
  ers_instance_number      = try(var.application.ers_instance_number, "02")
  scs_high_availability    = try(var.application.scs_high_availability, false)
  application_server_count = try(var.application.application_server_count, 0)
  webdispatcher_count      = try(var.application.webdispatcher_count, 0)
  vm_sizing                = try(var.application.vm_sizing, "Default")
  app_nic_ips              = try(var.application.app_nic_ips, [])
  scs_lb_ips               = try(var.application.scs_lb_ips, [])
  scs_nic_ips              = try(var.application.scs_nic_ips, [])
  web_lb_ips               = try(var.application.web_lb_ips, [])
  web_nic_ips              = try(var.application.web_nic_ips, [])

  authenticationLinux = try(var.application.authentication,
    {
      "type"     = "key"
      "username" = "azureadm"
  })

  authenticationWindows = try(var.application.authentication,
    {
      "type" : "password",
      "username" : "azureadm",
      "password" : "Sap@hana2019!"
  })

  # OS image for all Application Tier VMs

  app_customimage = { "source_image_id" : try(var.application.os.source_image_id, "") }

  app_marketplaceimage = try(var.application.os,
    {
      os_type   = "Linux"
      publisher = "suse"
      offer     = "sles-sap-12-sp5"
      sku       = "gen1"
  "version" : "latest" })

  app_image = try(var.application.os.source_image_id, null) == null ? local.app_marketplaceimage : local.app_customimage 

  app_ostype = try(var.application.os.os_type, "Linux")

  authentication = local.app_ostype == "Linux" ? local.authenticationLinux : local.authenticationWindows

}

# Imports Disk sizing sizing information
locals {
  sizes = jsondecode(file("${path.root}/../app_sizes.json"))
}

locals {
  # Subnet IP Offsets
  # Note: First 4 IP addresses in a subnet are reserved by Azure
  ip_offsets = {
    scs_lb = 4 + 1
    web_lb = 4 + 3
    scs_vm = 4 + 6
    app_vm = 4 + 10
    web_vm = 4 + 20
  }

  # Default VM config should be merged with any the user passes in
  app_sizing = lookup(local.sizes.app, local.vm_sizing, lookup(local.sizes.app, "Default"))

  scs_sizing = lookup(local.sizes.scs, local.vm_sizing, lookup(local.sizes.scs, "Default"))

  web_sizing = lookup(local.sizes.web, local.vm_sizing, lookup(local.sizes.web, "Default"))

  # Ports used for specific ASCS, ERS and Web dispatcher
  lb-ports = {
    "scs" = [
      3200 + tonumber(local.scs_instance_number),          # e.g. 3201
      3600 + tonumber(local.scs_instance_number),          # e.g. 3601
      3900 + tonumber(local.scs_instance_number),          # e.g. 3901
      8100 + tonumber(local.scs_instance_number),          # e.g. 8101
      50013 + (tonumber(local.scs_instance_number) * 100), # e.g. 50113
      50014 + (tonumber(local.scs_instance_number) * 100), # e.g. 50114
      50016 + (tonumber(local.scs_instance_number) * 100), # e.g. 50116
    ]

    "ers" = [
      3200 + tonumber(local.ers_instance_number),          # e.g. 3202
      3300 + tonumber(local.ers_instance_number),          # e.g. 3302
      50013 + (tonumber(local.ers_instance_number) * 100), # e.g. 50213
      50014 + (tonumber(local.ers_instance_number) * 100), # e.g. 50214
      50016 + (tonumber(local.ers_instance_number) * 100), # e.g. 50216
    ]

    "web" = [
      80,
      3200
    ]
  }

  # Ports used for ASCS, ERS and Web dispatcher NSG rules
  nsg-ports = {
    "web" = [
      {
        "priority" = "101",
        "name"     = "SSH",
        "port"     = "22"
      },
      {
        "priority" = "102",
        "name"     = "HTTP",
        "port"     = "80"
      },
      {
        "priority" = "103",
        "name"     = "HTTPS",
        "port"     = "443"
      },
      {
        "priority" = "104",
        "name"     = "sapinst",
        "port"     = "4237"
      },
      {
        "priority" = "105",
        "name"     = "WebDispatcher",
        "port"     = "44300"
      }
    ]
  }

  # Ports used for the health probes.
  # Where Instance Number is nn:
  # SCS (index 0) - 620nn
  # ERS (index 1) - 621nn
  hp-ports = [
    62000 + tonumber(local.scs_instance_number),
    62100 + tonumber(local.ers_instance_number)
  ]

  #As we don't know if the server is a Windows or Linux Server we merge these
  app_vms = flatten([[for vm in azurerm_linux_virtual_machine.app : {
    name = vm.name
    id   = vm.id
    }], [for vm in azurerm_windows_virtual_machine.app : {
    name = vm.name
    id   = vm.id
    }]
  ])

  # Create list of disks per VM
  app-data-disks = flatten([
    for vm in local.app_vms : [
      for disk_spec in local.app_sizing.storage : {
        virtual_machine_id = vm.id
        name               = format("%s-%s", vm.name, disk_spec.name)
        disk_type          = lookup(disk_spec, "disk_type", "Premium_LRS")
        size_gb            = lookup(disk_spec, "size_gb", 512)
        caching            = lookup(disk_spec, "caching", false)
        write_accelerator  = lookup(disk_spec, "write_accelerator", false)
      }
    ]
  ])

  #As we don't know if the server is a Windows or Linux Server we merge these
  scs_vms = flatten([[for vm in azurerm_linux_virtual_machine.scs : {
    name = vm.name
    id   = vm.id
    }], [for vm in azurerm_windows_virtual_machine.scs : {
    name = vm.name
    id   = vm.id
    }]
  ])

  scs-data-disks = flatten([
    for vm in local.scs_vms : [
      for disk_spec in local.scs_sizing.storage : {
        virtual_machine_id = vm.id
        name               = format("%s-%s", vm.name, disk_spec.name)
        disk_type          = lookup(disk_spec, "disk_type", "Premium_LRS")
        size_gb            = lookup(disk_spec, "size_gb", 512)
        caching            = lookup(disk_spec, "caching", false)
        write_accelerator  = lookup(disk_spec, "write_accelerator", false)
      }
    ]
  ])

  #As we don't know if the server is a Windows or Linux Server we merge these
  webdisp_vms = flatten([[for vm in azurerm_linux_virtual_machine.web : {
    name = vm.name
    id   = vm.id
    }], [for vm in azurerm_windows_virtual_machine.web : {
    name = vm.name
    id   = vm.id
    }]
  ])


  web-data-disks = flatten([
    for vm in local.webdisp_vms : [
      for disk_spec in local.web_sizing.storage : {
        virtual_machine_id = vm.id
        name               = format("%s-%s", vm.name, disk_spec.name)
        disk_type          = lookup(disk_spec, "disk_type", "Premium_LRS")
        size_gb            = lookup(disk_spec, "size_gb", 512)
        caching            = lookup(disk_spec, "caching", false)
        write_accelerator  = lookup(disk_spec, "write_accelerator", false)
      }
    ]
  ])
}
